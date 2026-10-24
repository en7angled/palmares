# Functional use cases — the attestation protocol

**What this document is for.** It describes every action the on-chain attestation layer supports, as a
frontend has to implement it: who may act, what the UI must collect, which endpoint it calls, what the
user signs, and what the screen can read back afterwards. It covers the *attestation protocol* only —
claimable profiles, countersigned attestations, disputes. The governance read surface (DReps, votes,
governance actions, metrics) is a separate half of the product and a separate document.

**Everything here is read out of the code.** Request and response shapes come from the two live Swagger
documents (`http://127.0.0.1:8082/swagger-api.json` and `http://127.0.0.1:8083/swagger-api.json`);
request bodies come from `scripts/smoke_attest_flow.sh`, which drives the whole flow end to end against
a live preprod deployment and is the executable form of this document. Where a fact could not be
checked, the line says `UNVERIFIED:` and what was missing.

**Status.** The protocol is live on preprod. The deployed script hashes are in
`config/config_palmares_validators.json`; the write service reports `provider: "node-kupo"`,
`network: "preprod"`, `deployed_scripts: true`, `oracle_paused: false` on `GET /status`.

**The two services.**

| Service | Port | Auth | What it is |
|---|---|---|---|
| `interaction-api` | 8082 | HTTP Basic on every write route | Builds unsigned transactions. Holds no key, signs nothing. |
| `query-api` | 8083 | none, public | Serves the projections a screen reads. |

**One structural fact that shapes every screen.** The read surface is fed by a separate projector
(`attest-sync`) that polls Kupo **asynchronously**. A record does not exist in `query-api` the instant
its transaction confirms. Every screen that writes must **poll** the read endpoint until the value
appears; none may assume. `scripts/smoke_attest_flow.sh:147-159` does exactly this, with a bounded
timeout, and says why.

---

## 1. The actors

The protocol has no accounts, no logins and no roles table. Authority is **possession of a token** or
**control of a key**, checked by the validators at transaction time. The product's own names:

| Actor | What they must hold to act | What they can see without acting |
|---|---|---|
| **Visitor** | nothing | the entire read surface: every profile, every attestation (accepted and pending), every dispute and verdict, and the chain proof (`tx_hash`, `slot`, `output_index`) of each. This is the primary audience (spec §3). |
| **Profile owner** | a CIP-30 wallet holding that profile's **user token**. The user token *is* the authority: it moves by plain transfer with no validator involved, and a lost user token is a profile nobody can act for (`onchain-flows.md:682, 928`). | everything a visitor sees. |
| **Issuer** | a wallet holding the **issuing** profile's user token. Any profile may issue about any other; the protocol does not rank issuers — "authority is not a rank but the verifiable identity of the issuer" (spec §4.3). | — |
| **Subject** | a wallet holding the **subject** profile's user token, to countersign. | — |
| **Credential holder** | the key (a signature) or the script (a spendable UTxO at its own address) behind a `drep1…`, `cc_cold1…` or `cc_hot1…` identifier. Needed to bind a credential, and needed *alone* to un-bind one. | — |
| **Disputer** | a wallet holding **any** profile's user token, plus the deposit the oracle currently requires. | — |
| **Oracle admin** | the key or script credential in the oracle datum's `opAdmin`. Writes dispute verdicts and changes protocol parameters. | — |
| **Anyone, with no authority at all** | a wallet that can pay a network fee. Can close an undecided dispute past its deadline (`/expire-dispute`) and sweep dust. | — |

Three notes a designer needs:

- **There is no "my account" concept and no route that answers "which profiles do I own".** The
  projections record no owner address. See §6, gap G1.
- **The admin is not reachable over HTTP for anything but a verdict.** Every `AdminActionType`
  constructor is refused in a request body with a 400 that explains why
  (`DomainTypes/Core/Actions.hs:476-481`). Pause, parameter changes and key rotation are admin-CLI
  only. The one exception is `/resolve-dispute`, and the reason is stated in the code: the oracle
  validator requires the admin's signature on chain, so the service can only ever return an unsigned
  transaction — and there, that transaction *is* the product.
- **Six profile kinds**, wire values exactly: `person_d_rep`, `organization`, `committee`,
  `community`, `vendor`, `auditor`. Note the spelling `person_d_rep` — three underscores, derived
  mechanically from the constructor `PersonDRep`. Four of the six (organization, community, vendor,
  auditor) correspond to no on-chain credential and never need a credential binding
  (`ServiceRequests.hs:42-46`).

---

## 2. Use cases

### 2.0 The shape of every write (read this once)

Every write is the same four steps. The per-use-case sections below name only what differs.

```
1. POST <route>            →  200, body = a JSON *string*: the unsigned transaction's CBOR hex
                              (a refusal is a JSON *object*: {"code":…,"message":…})
2. wallet.signTx(cborHex)  →  CIP-30 witness SET CBOR hex (what api.signTx returns)
3. POST /submit-tx         →  200, body = a JSON string: the transaction id
   {"tx_unsigned": <the hex from step 1>, "tx_wit": <the hex from step 2>}
4. GET /tx-status/{txId}   →  {"tx_id": "…", "confirmed": false|true}   — poll until true
5. GET <query-api route>   →  poll until the projection appears (ASYNCHRONOUS, see §2.11)
```

Step 1's success body is a bare JSON string, not an object. `smoke_attest_flow.sh:173-174` uses exactly
that to tell success from refusal without a second request: `jq -re 'strings'` succeeds on a
transaction and fails on an error object.

**Every write route is HTTP Basic.** Measured: `GET /tx-status/…` without credentials returns `401`
with an empty body. The published Swagger document does **not** declare this —
`securityDefinitions` is `null`, because the document is generated from `PublicAPI`, which excludes the
auth wrappers (`interaction-api/RestAPI.hs:229-230`). See §6, gap G9.

**`user_addresses` is on every request body, and its inner keys are camelCase** while every field
around them is snake_case. This is a known, unfixed inconsistency, called out at
`smoke_attest_flow.sh:199-203`:

```json
"user_addresses": {
  "usedAddresses": ["00e1cbb80d…"],
  "changeAddress": "00e1cbb80d…",
  "reservedCollateral": "8282582004ff…"
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `usedAddresses` | array of address | yes | every UTxO-bearing address of the connected wallet. The builder looks up user tokens here, so a profile whose token sits at an address not listed reads as `ProfileNotFound`. |
| `changeAddress` | address | yes | |
| `reservedCollateral` | tx-out-ref CBOR hex | no | the browser wallet's reserved collateral, if it sets one. |

**Addresses are RAW CBOR HEX, 114 characters — not bech32.** `addr_test1…` is refused.
`GYAddress`'s parser is `deserialiseFromRawBytesHex`. The Swagger `description` for `GYAddress` says
"Bech32-encoded Cardano address" and **is wrong about it**; its `format: cbor hex`, its
`minLength`/`maxLength` of 114 and its example are right (`attest-flow-smoke.md:93-97`). See §6,
gap G8.

**`recipient` is accepted by every write route and read by none of them.** Finding F8,
`onchain-flows.md:53`. Do not put a control in the UI for it.

**Ids are asset classes**, `<56-hex policy id>.<asset name hex>`, e.g.
`aabbccddeeff00112233445566778899aabbccddeeff001122334455.61747403`. One policy id for the whole
protocol; the asset name's first four bytes are a CIP-67 label that says what kind of thing it is
(§6, gap G2).

---

### 2.1 Create a profile

**Trigger.** A visitor decides to be represented in the registry.
**Actor.** Anyone with a funded wallet. No preconditions on chain beyond the protocol being deployed
and unpaused.
**It claims no credential.** Since ADR 0003 a profile mint binds nothing; binding is §2.2, a second
transaction. A `ClaimProfileRequest` has no `credential` and no `witness` field.

`POST /claim-profile`

| Wire field | Type | Required | What the UI collects |
|---|---|---|---|
| `kind` | enum: `person_d_rep` \| `organization` \| `committee` \| `community` \| `vendor` \| `auditor` | yes | a picker. Immutable after minting. |
| `name` | string | yes | **immutable once minted** — say so next to the field. |
| `description` | string | yes | editable later (§2.4). |
| `image_uri` | string | yes | a URI. The client hosts the image; the protocol stores only the string. |
| `user_addresses` | object | yes | from the wallet. |
| `recipient` | address | no | ignored — do not expose. |

From `smoke_attest_flow.sh:297-308`, verbatim:

```json
{
  "kind": "auditor",
  "name": "palmares-smoke-20261024T090000Z-issuer",
  "description": "issuer profile for smoke-20261024T090000Z",
  "image_uri": "ipfs://palmares-smoke-placeholder",
  "user_addresses": {
    "usedAddresses": ["00e1cbb80d…"],
    "changeAddress": "00e1cbb80d…"
  }
}
```

**What the user signs.** A transaction that mints two tokens under the protocol policy — a *reference*
token locked at the ProfilesValidator with the profile's datum, and a *user* token that lands in their
own change address. They are agreeing to lock the reference NFT plus `opMinUTxOValue` lovelace
**permanently** (there is no burn redeemer; `onchain-flows.md:923`), to pay the network fee, and
possibly a `fcProfileCreationFee` if the oracle has fees configured.

**State afterwards.** A profile exists on chain, owned by whoever holds the user token. `credential` is
null. The name can never change.

**How the UI learns it worked.** Poll `GET /profiles?q=<name>` until `.total` is `1`, lift
`.items[0].id`, then read `GET /profiles/{id}`. The smoke script does precisely this
(`:310-324`) and asserts `credential` is `null` before the claim, because that column is *derived* and
a null here proves the derivation is running.

---

### 2.2 Bind a governance credential to a profile

**Trigger.** A profile owner wants the registry to publish "this profile is `drep1y…`".
**Actor.** The profile owner **and** the credential holder, in one transaction. For a person who is
their own DRep that is one wallet; for an organization acting through a multisig it is two parties.
**Preconditions.** The profile exists on chain. The credential is a **CIP-129** identifier.

`POST /claim-credential`

| Wire field | Type | Required | What the UI collects |
|---|---|---|---|
| `profile_id` | asset class | yes | the profile being bound. |
| `credential` | string | yes | CIP-129: `drep1…`, `cc_cold1…`, `cc_hot1…`. **58 characters** for a DRep id. See §5. |
| `witness` | object, tagged | no | how a **script** credential proves control. Omit for a key credential. See §5. |
| `name` | string | yes | the *claim record's* own metadata — the binding is itself an attestation, so it carries name/description/image like any other. |
| `description` | string | yes | |
| `image_uri` | string | yes | |
| `user_addresses` | object | yes | must include the address holding the profile's user token. |

From `smoke_attest_flow.sh:330-335`:

```json
{
  "profile_id": "aabb….7375626a02",
  "credential": "drep1y…",
  "witness": {"tag": "key"},
  "name": "credential claim for smoke-20261024T090000Z",
  "description": "binds the subject profile to its DRep credential",
  "image_uri": "ipfs://palmares-smoke-placeholder",
  "user_addresses": {"usedAddresses": ["00e1cbb80d…"], "changeAddress": "00e1cbb80d…"}
}
```

**What the user signs.** A transaction that spends the profile's user token (the profile's consent,
rule `Mf`) and is authorised by the credential (the credential's consent, rule `Mc3`), and mints a
`credential_claim` attestation. They are agreeing to two things: that this profile claims that
credential, and to lock a second reference NFT plus min-ADA permanently — "a credentialled profile now
locks min-ADA twice" (`onchain-flows.md:916-917`).

**Nothing is checked about uniqueness.** Not that the claim is the first, not that only one profile
claims a credential. The log is the record; the read layer resolves it. A bogus claim is contestable
through a dispute (§2.7) and endable by the credential (§2.3).

**State afterwards.** A `credential_claim` attestation exists, self-issued (subject = issuer = this
profile). The profile's published `credential` field is **derived** from it: the latest
`credential_claim` with no later `credential_withdrawal` naming the same credential.

**How the UI learns it worked.** Poll `GET /profiles/{id}` until `.credential != null`. Then
`.credential_is_script` tells a key credential from a script one, decoded from the identifier's header
byte rather than guessed. Note that the stored string is the **canonical** CIP-129 rendering, not
necessarily the spelling the user typed (`smoke_attest_flow.sh:338-342`).

**A claim record is never accepted and does not need to be.** `Mc1` makes it self-issued, so the
subject's consent is already in the mint. Expect it to sit at `accepted: false` for ever, and do not
render that as a problem — the smoke script asserts exactly one permanently-pending record for this
reason (`:393-397`).

---

### 2.3 End a credential binding

**Trigger.** A credential holder discovers a profile they do not control is claiming their credential;
or a legitimate binding is retired (a rotated CC hot key).
**Actor.** The **credential holder alone**. This is deliberately *not* the profile owner's route: the
case it exists for is a profile that claimed somebody else's credential, and that profile's user token
is held by whoever did it. Requiring it would hand the remedy to the only party that must not have it
(`ServiceRequests.hs:192-200`).

`POST /withdraw-credential` — same body as `/claim-credential`.

**What the user signs.** A transaction authorised by the credential only; the profile's user token is
**not** required. It mints a `credential_withdrawal` attestation.

**Nothing is erased.** The claim stays on chain; this record is appended beside it, and the read layer
stops publishing the binding. A malicious withdrawal costs a fee and leaves a visible, permanent fact.

**State afterwards.** `GET /profiles/{id}` → `credential` becomes `null`. Both the claim and the
withdrawal remain visible in `GET /profiles/{id}/attestations` as `kind: "credential_claim"` and
`kind: "credential_withdrawal"`.

**How the UI learns it worked.** Poll `GET /profiles/{id}` until `.credential` is `null`. A withdrawal
naming a *different* credential than the profile currently publishes changes nothing and gives no
error — a silent no-op the UI should guard against by pre-filling the field from the profile's own
`credential`.

---

### 2.4 Edit a profile's metadata

**Trigger.** The owner wants a new description or image.
**Actor.** The profile owner (holds the user token).

`POST /update-profile`

| Wire field | Type | Required | Notes |
|---|---|---|---|
| `profile_id` | asset class | yes | |
| `image_uri` | string | **yes** | required even when unchanged — pre-fill it from the current value. |
| `description` | string | no | omit to keep the current one. |
| `user_addresses` | object | yes | |

**The name is immutable** and there is no field for it. **There is no delete** — not here, not
anywhere, and the admin CLI has no `delete-profile` for the same reason.

**How the UI learns it worked.** Poll `GET /profiles/{id}` until `description`/`image_uri` match what
was sent. There is no version field or `updated_at` to compare, so a no-op edit is indistinguishable
from a pending one.

---

### 2.5 Issue an attestation

**Trigger.** An issuer wants to record a statement about a subject — a delivered milestone, a passed
audit, an affiliation, a held mandate, an endorsement.
**Actor.** The issuing profile's owner.
**Preconditions.** Both profiles exist on chain. The subject's existence is checked off chain and
refused as `SubjectProfileNotFound` (404), because the chain cannot refuse it: an attestation about a
profile nobody minted can never be countersigned, so it would stay pending for ever and nothing can
remove it (`Exceptions.hs:56-64`).

`POST /issue-attestation`

| Wire field | Type | Required | What the UI collects |
|---|---|---|---|
| `subject_profile_id` | asset class | yes | who the statement is about. |
| `issuer_profile_id` | asset class | yes | who is saying it; the wallet must hold this profile's user token. |
| `kind` | enum, see below | yes | |
| `name` | string | yes | |
| `description` | string | yes | |
| `image_uri` | string | yes | |
| `other_metadata` | array of `[key, value]` string pairs | **yes** (send `[]`) | free-form metadata. Keys `name`, `description`, `image` are reserved. Capped at 16 entries of 64/256 bytes (`CIP68.hs:129-139`). |
| `claimed_period` | `[from, to]`, ISO-8601 | no | both bounds or neither. See the warning below. |
| `user_addresses` | object | yes | |

`kind` accepts seven values: `milestone_delivered`, `audit_passed`, `affiliation`, `role_held`,
`endorsement`, `credential_claim`, `credential_withdrawal`. **The last two do not work on this route**
— they build a transaction the chain refuses. See §6, gap G7, and use §2.2 / §2.3 instead.

**There is no `date` field.** The issuance date is derived from the chain tip, because the minting
policy requires it to fall inside the transaction's validity interval — so a client-supplied date had
exactly one acceptable value and every other value was a 400 (`ServiceRequests.hs:103-107`).

**`claimed_period` is SELF-REPORTED and never chain-verified.** The only check is `from <= to`, and it
is off-chain only. The UI must not render it alongside `date` as though both were established: `date`
is bounded by the transaction's validity interval, `claimed_period` is bounded by nothing. The read
surface deliberately offers no filter and no sort on it, because "a range query over it would read as
though the chain had checked it" (`query-api/RestAPI.hs:1477-1480`).

From `smoke_attest_flow.sh:350-357`:

```json
{
  "subject_profile_id": "aabb….7375626a02",
  "issuer_profile_id": "aabb….69737375657201",
  "kind": "role_held",
  "name": "palmares-smoke-20261024T090000Z-attestation",
  "description": "attestation for smoke-20261024T090000Z",
  "image_uri": "ipfs://palmares-smoke-placeholder",
  "other_metadata": [["smoke_run", "smoke-20261024T090000Z"]],
  "claimed_period": ["2025-01-01T00:00:00Z", "2025-12-31T00:00:00Z"],
  "user_addresses": {"usedAddresses": ["00e1cbb80d…"], "changeAddress": "00e1cbb80d…"}
}
```

**What the user signs.** A transaction that spends their issuing profile's user token and mints **one**
reference token (no user token — an attestation has no transferable owner), locked at the
AttestationsValidator with `isAccepted = false`. They are agreeing to make a permanent, public
statement and to lock min-ADA for ever.

**State afterwards.** The attestation is **pending**. It is already public and already visible — the
unfiltered `/attestations` list includes unaccepted claims, and `accepted` has no default
(`query-api/RestAPI.hs:1481-1482`). A pending attestation is a claim the subject has not acknowledged;
the UI must label it as such rather than as a record.

**How the UI learns it worked.** Poll `GET /attestations?subject=<id>&issuer=<id>` until `.total` is
`1`, lift `.items[0].id`, then `GET /attestations/{id}` and read `.attestation.accepted` (`false`),
`.attestation.tx_hash` and `.attestation.output_index` for the chain proof.

---

### 2.6 Countersign an attestation (accept)

**Trigger.** The subject agrees with what was said about them.
**Actor.** The subject profile's owner, and only them (rule `A5` wants that user token).
**Preconditions.** The attestation exists and is not already accepted.

`POST /accept-attestation`

| Wire field | Type | Required |
|---|---|---|
| `attestation_id` | asset class | yes |
| `user_addresses` | object | yes — must include the address holding the **subject** profile's user token |

```json
{"attestation_id": "aabb….61747403",
 "user_addresses": {"usedAddresses": ["00e1cbb80d…"], "changeAddress": "00e1cbb80d…"}}
```

**What the user signs.** A transaction that spends their own profile's user token beside the
attestation UTxO and re-locks it with `isAccepted = true`.

**This is IRREVERSIBLE.** There is no un-accept redeemer; the flag is written once and `A3` refuses a
second accept. The signing card must say so. The countersignature is the whole point of the design —
it is what makes the record a two-party fact rather than one party's assertion (spec §11, the ERC-8004
post-mortems).

**State afterwards.** `accepted: true`, for ever.

**How the UI learns it worked.** Poll `GET /attestations/{id}` until `.attestation.accepted` is `true`.
**The tx-proof moves.** The projection is upserted by attestation id from whichever output currently
holds it, so `.attestation.tx_hash` after acceptance names the *accepting* transaction, not the issuing
one (`smoke_attest_flow.sh:387-391`). A UI that cached the issuing hash will show a UTxO that no longer
exists.

---

### 2.7 Open a dispute

**Trigger.** Someone believes an attestation is false.
**Actor.** Any profile owner. There is no standing requirement — the disputer need not be the subject,
the issuer or anyone named in the record.
**Preconditions.** The target attestation exists. The wallet holds the opening profile's user token and
enough ADA for the deposit plus min-ADA plus fees. The deposit amount is the oracle's current
`opDisputeDeposit`.

`POST /open-dispute`

| Wire field | Type | Required | What the UI collects |
|---|---|---|---|
| `attestation_id` | asset class | yes | the attestation being contested. |
| `opened_by_profile_id` | asset class | yes | the disputing profile; the wallet must hold its user token. |
| `name` | string | yes | |
| `description` | string | yes | **what is being contested, and why** — this is the substance of the dispute. |
| `image_uri` | string | yes | |
| `deposit_to` | address | no | **omit it.** See below. |
| `user_addresses` | object | yes | |

**`deposit_to` — omit it.** The default is the address holding the opener's user token, which is the one
address the on-chain rule `Md8` is satisfied by for free, because spending that UTxO is how the opener
authorises in the first place. If the UI does offer the field, it must be an address listed in
`user_addresses`, or the request is refused as `DepositAddressNotSpendable` **before** the user signs. A
**script** address is refused outright as `DepositAddressIsScript`: the refund is a plain output with no
datum, which a script cannot spend, so it would be lost. Both refusals exist because of real damage:
an address no real output can carry makes the dispute **unresolvable**, left open against its target for
ever, and the cost falls on the subject of the attestation rather than on the disputer
(`DomainTypes/Core/Actions.hs:340-361`).

From `smoke_attest_flow.sh:458-462`:

```json
{
  "attestation_id": "aabb….61747403",
  "opened_by_profile_id": "aabb….69737375657201",
  "name": "palmares-smoke-20261024T090000Z-dispute",
  "description": "dispute for smoke-20261024T090000Z",
  "image_uri": "ipfs://palmares-smoke-placeholder",
  "deposit_to": "00e1cbb80d…",
  "user_addresses": {"usedAddresses": ["00e1cbb80d…"], "changeAddress": "00e1cbb80d…"}
}
```

**What the user signs.** A transaction that spends their profile's user token and mints a dispute
reference token, locked at the DisputesValidator with the **deposit** inside it. They are agreeing to
lock the deposit until the dispute closes, and to lock min-ADA plus the NFT permanently. **The deposit
comes back on every outcome** — upheld, rejected or expired. There is no punitive verdict, because a
registry that charged for contesting a false claim would discourage contesting one
(`DisputesValidator.hs:245-250`). The UI should say this: contesting costs network fees and nothing
else.

**The deadline is set here and nowhere else.** `disputeStaleAfter = openedAt + opDisputeTimeoutMs` is
written into the dispute's own datum at open time, so a later admin reprice of the timeout cannot move
it. The deployed default is 30 days (`onchain-flows.md:652`). **The deadline is not published by the
read API** — see §6, gap G4.

**The attestation is not touched.** It is neither spent nor referenced. A dispute is published *beside*
what it contests and never hides it.

**One open dispute per attestation is not a protocol rule.** Off chain the service refuses a duplicate
as `DisputeAlreadyOpen` as a courtesy; on chain N disputes cost N deposits and nothing bounds the count.

**How the UI learns it worked.** Poll `GET /disputes?target=<attestationId>` until `.total` is `1`.
`verdict` is `null` while it is open. `GET /attestations/{id}` also carries up to 50 disputes **inline**
— and that is the signal a UI must render, because "an undisputed-looking attestation is exactly the
wrong thing to show for a disputed one" (`query-api/RestAPI.hs:1501-1504`).

---

### 2.8 Resolve a dispute (a verdict)

**Trigger.** The arbiter decides.
**Actor.** Two parties in sequence: *anyone* may call the route to produce the transaction, but only
the **oracle admin** can sign it — the oracle validator requires that signature on chain (`D1`).
**Preconditions.** The dispute exists and carries no verdict.

`POST /resolve-dispute`

| Wire field | Type | Required | Notes |
|---|---|---|---|
| `dispute_id` | asset class | yes | |
| `verdict` | enum: `upheld` \| `rejected` | yes | `expired` is in the enum and is **refused here** as `DisputeVerdictNotAFinding`. Only the clock writes `expired`. |
| `user_addresses` | object | yes | the wallet that funds the network fee. It need not be the admin's. |

```json
{"dispute_id": "aabb….64737004", "verdict": "upheld",
 "user_addresses": {"usedAddresses": ["00e1cbb80d…"], "changeAddress": "00e1cbb80d…"}}
```

**What the admin signs.** A transaction that spends the dispute UTxO, re-locks it with the verdict
recorded, and pays the deposit back to the address the opener named. **Irreversible** — a verdict is
written once and never unset (`D3`).

**An upheld dispute does not delete, hide or un-accept the attestation.** The smoke script asserts all
three (`:492-494`). The attestation stays `accepted: true` and stays in the subject's track record. The
UI's job is to publish the verdict *beside* the record, not to suppress the record.

**State afterwards.** Terminal. `verdict` is `upheld` or `rejected`; the deposit has left the UTxO.

**How the UI learns it worked.** Poll `GET /disputes?target=<attestationId>` until
`.items[0].verdict` is `"upheld"`, or `GET /attestations/{id}` → `.disputes[0].verdict`.

**Two things a UI must handle here.** There is no route and no field that says *who the admin is*, so a
screen cannot tell the connected wallet whether it may sign (§6, gap G5). And if the protocol is paused,
this route builds a transaction anyway and the failure arrives as a misleading
`400 InsufficientFunds` — finding F3, `onchain-flows.md:48, 979`.

---

### 2.9 Expire a dispute (close with no finding)

**Trigger.** A dispute's deadline passed with no verdict.
**Actor.** **Anyone.** This is the one write in the protocol that needs no authority at all, and that
is the point: "an escape hatch that the admin can gate — by pausing, or by simply holding the only key
— is not an escape hatch" (`DisputesValidator.hs:172-176`). It works while the protocol is paused.
**Preconditions.** The dispute carries no verdict, and its own `disputeStaleAfter` has passed.

`POST /expire-dispute`

| Wire field | Type | Required |
|---|---|---|
| `dispute_id` | asset class | yes |
| `user_addresses` | object | yes — only to pay the network fee |

**What the user signs.** A transaction that closes the dispute as `expired` and returns the deposit to
the address **the opener** named. A stranger who builds this pays the fee and keeps nothing — which is
precisely why it is safe to make it permissionless.

**`expired` is NOT a finding against either party.** Nobody ruled. The read layer must not render an
expired dispute the way it renders an upheld one; the DTO's own description says so
(`DisputeRow`, query swagger). Three states are "resolved" by the `resolved=true` filter — `upheld`,
`rejected` *and* `expired` — so a screen that wants findings only must read the verdict **value**, not
the flag.

**How the UI learns it worked.** Poll `GET /disputes?target=<id>` until `.items[0].verdict` is
`"expired"`.

---

### 2.10 Read: browse, verify, inspect

These need no wallet and no auth. All are `GET` on `query-api` (port 8083).

| Route | Answers | Key parameters |
|---|---|---|
| `/profiles` | the registry list | `limit` (max 200, default 50), `offset`, `kind` (repeatable), `claimed` (bool), `q` (matches name and description, case-insensitive, `%`/`_` literal), `order_by` (`id`\|`name`\|`description`\|`type`\|`registered_at`), `sort_order`. Default: `registered_at` descending. |
| `/profiles/{profile-id}` | one profile | 404 `profile_not_found` |
| `/profiles/by-credential/{credential}` | **the verify direction**: which profiles claim this credential | `limit`, `offset`. **CIP-129 DRep ids only.** |
| `/profiles/{profile-id}/attestations` | a profile's **track record** — what others say about it | `limit`, `offset`, `sort_order`. **Accepted first, then newest**, with no `order_by`: sorting unacknowledged claims to the top would make a page of them look like a record. 404 on a missing profile rather than an empty page. |
| `/attestations` | all attestations, both directions | `subject`, `issuer`, `kind` (repeatable), `accepted` (bool, **no default**), `date_from`, `date_to`, `order_by` (`id`\|`date`\|`subject`\|`issuer`\|`name`), `sort_order`, `limit`, `offset` |
| `/attestations/{attestation-id}` | one attestation **with its disputes inline** (max 50), read in one transaction so they are the same snapshot | 404 `attestation_not_found` |
| `/disputes` | all disputes | `target`, `resolved` (bool = `verdict IS NOT NULL`), `sort_order`, `limit`, `offset`. Ordered by `opened_at`, newest first; no `order_by`. |
| `/status` | the projector's own health | see §2.11 |
| `/health`, `/ready` | liveness / readiness | `/ready` 503s when the index is behind |

**The verify flow is `/profiles/by-credential/`, and `total` is the answer to "is this contested".**
`0` is an unclaimed credential, `1` is a single claim, more than `1` means several profiles claim the
same credential **and the API picks no winner** — a legitimate state a verification screen must render
honestly. Rows are ordered oldest-claim-first, by slot, so the first row is deterministically the first
claimant.

Response shapes, from the query-api Swagger `definitions`:

`AttestProfileRow` — required: `id`, `name`, `description`, `image_uri`, `kind`, `slot`, `block_hash`;
optional: `credential`, `credential_is_script`.

`AttestationRow` — required: `id`, `subject`, `issuer`, `kind`, `date`, `accepted`, `name`,
`description`, `image_uri`, `other_metadata`, `slot`, `block_hash`, `tx_hash`, `output_index`;
optional: `claimed_period`, `credential`.

`DisputeRow` — required: `id`, `target`, `opened_by`, `opened_at`, `deposit`, `name`, `description`,
`image_uri`, `slot`, `block_hash`; optional: `verdict`.

`AttestationDetailResponse` — `{attestation: AttestationRow, disputes: [DisputeRow]}`.

Every list is a page: `{items, total, limit, offset, next_cursor}`. Measured live against the
deployment, with the projections currently empty:

```json
{"items": [], "total": 0, "limit": 2, "offset": 0, "next_cursor": null}
```

**`slot` is the only time a projection row carries**, and it is published **raw**. The service holds no
slot configuration, and "a second slot-to-time conversion that can disagree with the chain's is worse
than a slot number" (`query-api/RestAPI.hs:1389-1392`). The UI must convert slot → wall time itself.
See §6, gap G3.

---

### 2.11 Wait for a projection (every write ends here)

**The read surface is fed asynchronously.** `attest-sync` polls Kupo and writes the projections; a
record appears some time after its transaction confirms. There is no push, no webhook and no
`Retry-After`. **Every screen that writes must poll.**

`GET /status` on query-api carries the projector's self-report:

```json
{"network": "preprod", "attest_lag_seconds": null, "attestation": null}
```

(measured live — `null` on both, because this deployment has no projector running against its
database.) When a projector is present, `attestation` carries the applied slot, Kupo's tip as the
projector last saw it, the lag, a `state` of `syncing` | `following` | `rolled_back` | `error`,
`last_sync_at`, `is_ready`, the policy it follows and the last error. The same three facts travel on
**every** response as the headers `X-Attest-Slot`, `X-Attest-Lag-Seconds` and `X-Attest-State`
(`attest-flow-smoke.md:141-147`) — which is the cheapest way for a UI to show staleness: it is already
on the response the screen just made.

A poll that never resolves is diagnosable from that one object: `attestation: null` means no projector
at all; `state: "syncing"` means a backfill is still running; `state: "error"` means a tick raised.
**`/ready` deliberately stays green on `syncing`** — a projector mid-backfill is a healthy service
serving honest partial pages.

The reference implementation of the poll is `smoke_attest_flow.sh:147-159`: fixed 5-second interval,
600-second default ceiling, and a failure message that names the projector rather than blaming the
assertion.

---

### 2.12 The generic route (`/build-tx`)

`POST /build-tx` takes an `Interaction` — `{action, userAddresses, recipient}` — and covers every action
the dedicated routes cover plus `CleanupDustAction`. The `action` is a **tagged** object
(`{"tag": "<ConstructorName>", …fields}`), not a constructor-keyed one; the published schema was wrong
about this once and a client that followed it got a 400 on every write
(`DomainTypes/Core/Actions.hs:153-178`).

**A frontend should use the dedicated routes.** They take snake_case fields, carry the per-field
documentation, and apply the off-chain pre-checks. `/build-tx` is there for the admin CLI and for
clients that want one route; its `AdminAction` arm is refused in every request body.

---

## 3. State machines

Transitions are redeemers. **Nothing in this protocol burns and nothing deletes.** Every state UTxO,
and the reference NFT inside it, stays on chain for the life of the chain.

### A profile

```
            POST /claim-profile
  (none) ───────────────────────▶ [ Minted ]
                                      │
                                      │  POST /update-profile   (description, image only)
                                      └──────────┐
                                      ▲          │
                                      └──────────┘

  IMMUTABLE for ever:  id, kind, name
  MUTABLE:             description, image_uri
  NO terminal state.   There is no delete redeemer and no admin command to remove a profile.
  Authority:           possession of the user token. It moves by plain wallet transfer,
                       with no validator involved and no record in the projections.
```

The published `credential` is **not a field on this machine** — it is derived from the credential
attestations below:

```
  profile.credential = the credential of the latest `credential_claim` for this profile
                       with no later `credential_withdrawal` naming the same credential

  (none) ──/claim-credential──▶ [ bound ] ──/withdraw-credential──▶ [ unbound ]
                                     ▲                                   │
                                     └────── /claim-credential ──────────┘

  Both records are permanent. "Unbound" is a later fact appended beside the claim,
  never an erasure. The cycle may repeat; each pass locks another min-ADA.
```

### An attestation

```
        POST /issue-attestation
  (none) ─────────────────────▶ [ Pending ]  accepted: false
                                     │
                                     │  POST /accept-attestation   (the SUBJECT's user token)
                                     ▼
                               [ Accepted ]  accepted: true     ◀── TERMINAL. IRREVERSIBLE.
                                                                     No un-accept redeemer exists.

  A dispute does NOTHING to this machine:
      [ Pending ]  ──┐
      [ Accepted ] ──┴── a dispute is a SEPARATE UTxO pointing here.
                         The attestation is never spent, re-datumed or referenced.
                         An upheld dispute does not delete, hide or un-accept it.
                         The only effect on the read surface is that
                         GET /attestations/{id}.disputes becomes non-empty.

  Shapes that never reach Pending at all (refused at the mint):
    - subject is another attestation       → Mg requires a profile id (ADR 0006, lineage dropped)
    - self-issued, unless a credential kind → Mr
  A credential_claim / credential_withdrawal is self-issued by design and normally
  stays Pending for ever. That is correct, not stuck.
```

### A dispute

```
          POST /open-dispute                deposit LOCKED in the UTxO
  (none) ──────────────────────▶ [ Open ]   verdict: null
                                    │
            ┌───────────────────────┼───────────────────────┐
            │                       │                       │
   /resolve-dispute          /resolve-dispute        /expire-dispute
   verdict: upheld           verdict: rejected       (ANYONE, after
   (ADMIN signs)             (ADMIN signs)            disputeStaleAfter)
            │                       │                       │
            ▼                       ▼                       ▼
     [ Upheld ]              [ Rejected ]            [ Expired ]
     a FINDING               a FINDING               NOT a finding — nobody ruled

  All three are TERMINAL and IRREVERSIBLE: a verdict is written once and never unset (D3).
  The deposit is returned on ALL THREE outcomes, to the address the opener named.
  The deadline is fixed in the dispute's own datum at open time; repricing the
  protocol timeout never moves an open dispute's deadline.
  Expiry is the one write a pause cannot stop and no key can authorise.
```

### What is irreversible, stated plainly for the signing card

| Action | What can never be undone |
|---|---|
| Create a profile | the profile, its `kind` and its `name`; the locked reference NFT and min-ADA |
| Bind a credential | the claim record itself (the *binding* can be ended; the record cannot) |
| End a binding | the withdrawal record |
| Issue an attestation | the statement. It is public immediately, pending or not. |
| **Accept an attestation** | **the acceptance.** This is the one a user is most likely to click without thinking. |
| Open a dispute | the dispute record (the deposit comes back) |
| Resolve a dispute | the verdict |
| Expire a dispute | the `expired` close |

---

## 4. Every refusal a user can hit

Two layers refuse. **HTTP-level**: the service checks what it can before building, and the body is
`{"code": …, "message": …}` with a stable `code` a client matches on — the `message` "stays available
for display/fallback text matching" and may be reworded at any time
(`InteractionAppMonad.hs:72-77`). **On-chain**: a validator refuses during balancing, and the trace
codes are parsed out of the Plutus failure and returned as `400 ScriptRefused` with the codes in the
message (`Exceptions.hs:258-266`).

### 4.1 Write refusals (interaction-api)

| What the user did | Status | `code` | `message` (as shipped) | What the UI should say |
|---|---|---|---|---|
| sent no Basic credentials | 401 | *(empty body)* | — | "This build service needs credentials." Not a user-facing state — the frontend's proxy owns it. |
| named a profile whose user token is not in `user_addresses`; or its state UTxO is missing | 404 | `ProfileNotFound` | "Profile not found" | "You don't hold the token for this profile. Connect the wallet that does." |
| issued about a subject profile that does not exist | 404 | `SubjectProfileNotFound` | "The subject profile does not exist. An attestation about a profile that was never claimed can never be counter-signed…" | "That profile doesn't exist in the registry. Pick one from the list." |
| accepted an already-accepted attestation | 400 | `AttestationAlreadyAccepted` | "Attestation is already accepted" | "Already countersigned." Refresh the record. |
| named an attestation that does not exist | 404 | `AttestationNotFound` | "Attestation not found" | "Not found — it may not be projected yet. Try again in a moment." |
| used `name`, `description` or `image` as an `other_metadata` key | 400 | `AttestationOtherMetadataReservedKeys` | "other_metadata must not use reserved keys: name, description, image (CIP-68 standard fields)" | inline field error on the offending row. |
| sent `claimed_period` with `from > to` | 400 | `AttestationPeriodInverted` | "claimed_period ends before it begins. Send [from, to] with from <= to, or omit the field entirely — a period must have both bounds or neither." | inline date-range error. Catch it client-side first. |
| pasted a CIP-105 DRep id or a bare 56-char hex hash as `credential` | 400 | `CredentialMalformed` | "The credential must be a CIP-129 identifier (drep1…, cc_cold1…, cc_hot1…). A CIP-105 id or a bare hex hash carries no header byte…" | "That's the older CIP-105 form. Paste the CIP-129 id — 58 characters, starting `drep1y`." |
| claimed a **script** credential with no witness, or `{"tag":"key"}`, or with no spendable UTxO at the script's address | 400 | `ScriptCredentialHasNoUtxo` | "No spendable UTxO at the address of script <hash>, so this transaction cannot prove control of that script credential. The fix is one transaction: send a UTxO to that script address, then claim…" | "Send any UTxO to that script's address first, then claim. We can't prove control of a script that holds nothing." |
| named a `deposit_to` the wallet cannot spend from | 400 | `DepositAddressNotSpendable` | "deposit_to names an address this wallet holds no spendable UTxO at, and the protocol requires the deposit address to be spent from in the same transaction (Md8). Omit deposit_to…" | best fix: don't collect the field. Otherwise "Use one of your own funded addresses." |
| named a **script** `deposit_to` | 400 | `DepositAddressIsScript` | "deposit_to is a script address. The deposit is refunded as a plain output with no datum, which a script cannot spend, so it would be lost…" | "A script address can't receive the refund — it would be lost." |
| opened a second dispute against the same attestation | 400 | `DisputeAlreadyOpen` | "A dispute is already open against this attestation. Wait for it to be resolved before opening another; this is an off-chain courtesy, not a protocol rule." | "There's already an open dispute here." Link to it. |
| resolved or expired an already-decided dispute | 400 | `DisputeAlreadyResolved` | "Dispute already carries a verdict and cannot be resolved twice" | "Already decided." Refresh. |
| resolved with `verdict: "expired"` | 400 | `DisputeVerdictNotAFinding` | "A resolution must be a finding: only a passed deadline writes 'expired'" | don't offer `expired` in the verdict picker. |
| expired a dispute before its deadline | 400 | `DisputeNotStaleYet` | "Dispute cannot be expired yet: its deadline has not passed" | "Not yet — this dispute can be closed after <date>." **The UI cannot compute that date today**; see §6, gap G4. |
| sent `kind: credential_claim` to `/claim-credential`'s *wrong* route | 400 | `AttestationKindIsCredentialBinding` | "A credential binding is not issued here: use /claim-credential or /withdraw-credential, which take the credential and the witness that proves control of it" | **not currently reachable** — see §6, gap G7. |
| anything, while the protocol is paused | 503 | `ProtocolPaused` | "Protocol is paused" | a banner, not a form error. Poll `GET /status.oracle_paused`. |
| anything, while the reference scripts do not resolve | 503 | `DeployedScriptsNotReady` | "Deployed scripts are not ready" | "The registry is not accepting writes." |
| the oracle cannot be read | 404 / 500 | `OracleNotFound` / `OracleDatumInvalid` | "Oracle UTxO not found" / "Oracle datum invalid or unparseable" | a service-level error, not the user's. |
| wallet cannot pay | 400 | `InsufficientFunds` | "Not enough ADA in your wallet to cover the deposit and transaction cost." | show the deposit amount — the UI must get it from elsewhere; §6, gap G6. |
| the transaction is too big / too costly | 400 | `TxTooLarge` / `TxTooExpensive` | "This transaction is larger than the protocol allows" / "…needs more execution units than the protocol allows" | "Too much metadata — remove some entries." Adding ADA does **not** help, which is what the old answer wrongly implied. |
| a validator refused during balancing | 400 | `ScriptRefused` | "A validator refused this transaction: <trace codes>. These are on-chain trace codes; see docs/architecture/onchain-flows.md for what each one requires." | **never show this raw.** Map the first code (§4.2) or fall back to "The protocol refused this transaction (<codes>)." |
| the chain provider failed or rejected the submission | 502 | `ProviderError` | "The chain provider could not be reached or rejected the submission" | "Couldn't reach the chain. Retry." Safe to retry. |
| anything else | 500 | `InternalError` | "Internal server error" | generic. |
| sent an admin action in a body | 400 | *(aeson parse failure)* | "AdminActionType: admin actions are not accepted over HTTP…" | don't build this surface. |

### 4.2 On-chain refusals a user can actually reach

These arrive as `400 ScriptRefused` with the codes in the message. The ones a correct frontend can
still produce:

| Trace code | What it means | How the user hit it | What the UI should say |
|---|---|---|---|
| `Md8` | the deposit address must be an input of the opening transaction | a multi-address wallet whose chosen `deposit_to` contributes no input. The off-chain `DepositAddressNotSpendable` catches most of these first. | "Use a funded address for the refund, or let us choose one." |
| `Mda` | `deposit_to` is a script address | same mistake, caught on chain if it slips past `DepositAddressIsScript`. | as `DepositAddressIsScript`. |
| `Mc2` | a credential record must name a credential | `POST /issue-attestation` with `kind: credential_claim` or `credential_withdrawal`. **Reachable today**; see §6, gap G7. | "Use the credential-binding flow, not the attestation form." |
| `Mc3` | the credential did not prove control | a key credential whose key did not sign, or a script whose proving input was not spent. | "The credential's own signature (or its script's input) is missing from this transaction." |
| `Mg` | the subject must be a profile id | an attestation naming another attestation, a dispute or a user token as its subject. | "An attestation can only be about a profile." |
| `Mr` | a self-issued attestation is refused unless it is a credential binding | the UI pre-filled `issuer_profile_id == subject_profile_id`. | "A profile can't attest about itself." Guard this in the form. |
| `Mq` / `Md6` | the recorded date must sit inside a finite validity interval of at most 14.4 h | a wallet that widened the transaction's validity interval past 14.4 h. | "Your wallet changed the transaction's validity window. Try a different wallet." |
| `A3` | accepted once, never twice | a race between two tabs. | "Already countersigned." |
| `A7` / `M0` / `P6` / `D7` | the protocol is paused | a pause that landed between the build and the submit. | "The registry was paused while you were signing." |
| `D3` | a verdict is written once | a race on resolution. | "Already decided." |
| `D9` | the expiry deadline has not passed | a clock skew between the client and the chain. | "Not yet — try again shortly." |
| `D1` | the oracle admin must sign | `/resolve-dispute`'s transaction signed by the wrong key. | "Only the arbiter can sign this." |

### 4.3 Read refusals (query-api)

Measured live against the running service.

| What the user did | Status | Body | What the UI should say |
|---|---|---|---|
| asked for a profile id that is not projected | 404 | `{"code":"profile_not_found","message":"No profile with that identifier"}` | "No such profile." It may exist on chain and not be projected yet — offer a retry. |
| asked for an attestation id that names nothing | 404 | `{"code":"attestation_not_found",…}` | same. |
| asked `/profiles/by-credential/` with a CIP-105 id or a bare hex hash | 400 | `{"code":"invalid_drep_id","message":"Not a DRep identifier"}` | "Paste the CIP-129 id (58 characters, `drep1y…`)." **Not** "nobody claims it" — that would be a false negative dressed as a result. |
| asked `/profiles/by-credential/` with a `cc_cold1…` or `cc_hot1…` id | 400 | `{"code":"invalid_drep_id","message":"Not a DRep identifier"}` | **a real product gap** — see §6, gap G10. |
| sent `date_from` after `date_to` | 400 | `{"code":"invalid_time_range","message":"The time range is empty or reversed"}` | inline range error. |
| sent `limit` above 200, or a too-large `offset` | 400 | `{"code":"limit_too_large"}` / `{"code":"offset_too_large"}` | clamp client-side. |
| sent a bad enum value for `kind`, `order_by`, `sort_order` | 400 | `{"code":"invalid_parameter"}` | shouldn't happen from a controlled UI. |
| the index is behind or the database is gone | 503 | `{"code":"indexer_behind"}` / `{"code":"db_unavailable"}` / `{"code":"not_ready"}` | a global staleness banner. |

The full declared set is in `webapi-lib/Palmares/WebAPI/Envelope.hs:118-149`. Nothing on the read
surface is a 401 or a 403 — it is public, and the grouping in that type is the documentation of that
fact.

---

## 5. The two credential kinds, in UI terms

A credential is either a **key** (one person, one signing key) or a **script** (a multisig, a native
timelock, or a Plutus script). The claim rule is one sentence in the spec — "prove you can spend as
that credential" (§4.3) — and it resolves to two completely different user experiences. The protocol
treats the script case as the *normal* one, because "most committees and organizations act through a
multisig/script rather than a bare key" (spec §2).

Which kind a credential is **is encoded in its CIP-129 identifier's header byte**, so the UI can tell
before asking: `drep1y…` is a key, `drep1yw…` is a script (`0x22` vs `0x23`). Both render as 58
characters.

| | **Key credential** | **Script credential** |
|---|---|---|
| `witness` field | omit it, or send `{"tag": "key"}` | **required**, and must be one of the two script shapes |
| What proves control | a signature on the returned transaction | an input the script governs is **spent** in the returned transaction |
| What the user does | connects the wallet holding that key and signs once | (a) makes sure the script address holds a spendable UTxO; (b) supplies the script and, for Plutus, its redeemer; (c) gets the script's spending condition satisfied — which for a multisig means collecting *n* signatures the UI must orchestrate |
| `witness` payload | `{"tag": "key"}` | `{"tag": "simple_script", "script": <native script JSON>}` or `{"tag": "plutus_script", "script": "<script CBOR hex>", "redeemer": <script data>}` |
| Refused when | the key does not sign (on chain, `Mc3`) | the script holds no UTxO at its own address — refused **before building**, as `ScriptCredentialHasNoUtxo`, which carries the script hash |
| Read back as | `credential_is_script: false` | `credential_is_script: true` |

**Three UI consequences.**

1. **A script claim needs a prerequisite step the protocol cannot do for you.** A Plutus script that
   only votes or withdraws holds no UTxO at its own address, so there is nothing to spend. The error
   message spells out the fix — "send a UTxO to that script address, then claim" — and the UI should
   offer that as a step in the wizard rather than as an error.
2. **A script claim needs a second signature the API has no route for.** `/claim-credential` returns
   one unsigned transaction; a multisig's *n* signatures must be collected and merged by the client
   before `/submit-tx`. See §6, gap G11.
3. **Both kinds share a hash space, and the header byte is the only thing that tells them apart.** A
   key credential and a script credential can share a 28-byte hash and are *not* the same actor
   (`AttestProfileRow`'s own description says so). Never compare credentials by hash; compare the
   whole CIP-129 string, or read `credential_is_script`.

**Three roles, not one.** ADR 0006 made the claimed role part of the record:
`drep1…` (a DRep), `cc_cold1…` (a committee cold key) and `cc_hot1…` (a committee hot key) are **all**
claimable, in both key and script form. Before that, a committee cold credential was published as
`drep1…` of the same bytes — an identifier that resolves to nothing in GovTool or db-sync, so a reader
could not verify the claim they were being shown. **Stake credentials are not claimable** and never
were, despite spec §4.3 listing "a stake address" — `parseCredentialRoleCip129` accepts exactly three
HRPs (`DomainTypes/Core/Ids.hs:148-159`).

---

## 6. Gaps for the frontend

Each gap: what a screen needs, what exists, what is missing.

### G1. No way to answer "which profiles do I own"

**The screen needs** a "my profiles" view, and every write form needs to know which profile the
connected wallet can act for. This is the entry point to the entire wallet-side product.

**What exists.** Authority is possession of the **user token**. The projections record the profile's
reference-token id and nothing about who holds the matching user token — `AttestProfileRow` has no
owner, holder or address field. There is no `/profiles?owner=…` filter and no filter type for one
(`Transfer/Filters.hs:424-435` lists `kinds`, `claimed`, `credential`, `q` and nothing else).

**What is missing.** Either an owner column on the projection, or the frontend does it itself:
enumerate the wallet's assets via CIP-30 `getBalance`, keep every asset under the protocol policy id
(`648c6a732aa55efec29815bdd25cf65c565cf92619aadde1d31496d3` in the current deployment) whose asset
name starts with the CIP-67 user-token prefix `000de140`, replace those four bytes with the reference
prefix `000643b0`, and look the result up with `GET /profiles/{id}`. That derivation is
`deriveRefFromUserTN` (`onchain-lib/Palmares/Onchain/CIP68.hs:372-374`). It is implementable but it
is protocol knowledge pushed into the client, it is N requests for N profiles, and the policy id is
redeployment-dependent — **and the API publishes the policy id nowhere.** `GET /status` on
interaction-api returns `{provider, network, deployed_scripts, oracle_paused, version}` and no hashes.

### G2. An id format the UI must parse to know what it is looking at

**The screen needs** to render a link for a pasted or deep-linked id without first guessing which of
three routes to call.

**What exists.** Profiles, attestations and disputes all use the same shape:
`<56-hex policy>.<asset name hex>`, under one policy. The first four bytes of the asset name are a
CIP-67 label: `000643b0` (profile reference, label 100), `00001070` (attestation, private label 1),
`000020e0` (dispute, private label 2), `000de140` (user token, label 222).

**What is missing.** No endpoint resolves an arbitrary id to its kind, and nothing publishes the label
table. The UI must hard-code those four prefixes and branch on them, which also means it silently
breaks on a redeploy that changes the policy id (ADR 0007, "a redeploy is a new registry").

### G3. Every timestamp on a projection row is a raw slot number

**The screen needs** "claimed 3 days ago" on a profile card, and a date on a dispute row.

**What exists.** `AttestProfileRow` and `DisputeRow` carry `slot` (integer) and `block_hash`. The
decision is explicit and defended: the service holds no slot configuration, and a second
slot-to-time conversion that can disagree with the chain's is worse than a slot number
(`query-api/RestAPI.hs:1389-1392`). `AttestationRow` *does* carry `date` as ISO-8601 — but that is the
attestation's own datum field, not a conversion of its slot. `DisputeRow` carries `opened_at` as
ISO-8601, likewise from the datum.

**What is missing.** A profile has **no** time field at all beyond its slot, so "registered at" on a
profile card requires the frontend to carry preprod's and mainnet's slot-to-time parameters and do the
conversion — the exact duplication the API declined to do. And `order_by=registered_at` sorts by a
value the UI cannot display.

### G4. A dispute's deadline is not published

**The screen needs** "this dispute can be closed by anyone after <date>", and an enabled/disabled state
for the "close it" button.

**What exists.** `disputeStaleAfter` is written into the dispute's datum at open time and is
**absolute** — a later admin reprice cannot move it (`onchain-flows.md:416-420`). `D9` and the
off-chain `DisputeNotStaleYet` both compare against it.

**What is missing.** `DisputeRow` has no `stale_after`, no `expires_at` and no `timeout_ms`. The UI
cannot compute it either: `opened_at` is published, but `opDisputeTimeoutMs` is an oracle parameter
that **no HTTP endpoint exposes** (`GET /status` on interaction-api carries only `oracle_paused`). The
only way to read it is the admin CLI's `query-oracle`, which is what the smoke script does
(`:448-451`). So a UI can show "open" and nothing more, and the expire button is a blind retry
against a 400.

### G5. Nothing says who the arbiter is

**The screen needs** to decide whether to show the "resolve this dispute" form to the connected wallet,
and to tell a reader who holds that power.

**What exists.** `opAdmin` and `opArbiter` are `Credential` fields in the oracle datum, rotatable
(ADR 0005). `D1` requires the signature on chain.

**What is missing.** No endpoint publishes either credential. A UI either shows the resolve form to
everyone and lets the node refuse, or hides it from everyone and the arbiter uses the CLI.

### G6. The dispute deposit amount is not published

**The screen needs** "opening a dispute locks N ADA, refunded on any outcome" **before** the user
commits.

**What exists.** `opDisputeDeposit` lives in the oracle datum and is read by the builder at open time.
`DisputeRow.deposit` publishes the amount **after** the dispute exists.

**What is missing.** No read route for the current price. The smoke script gets it from
`admin query-oracle` (`:448-452`). Same for `opMinUTxOValue`, which is the other part of "what will
this cost me" on every mint. The honest UI today either omits the number or reads a stale copy of it
from somewhere else. This is the same missing object as G4 and G5: **an oracle-parameters read route
would close all three.**

### G7. `/issue-attestation` accepts two kinds it cannot build

**The screen needs** a `kind` picker whose values all work.

**What exists.** `AttestationType`'s wire enum has seven values and the Swagger `enum` lists all seven
on `/issue-attestation`. `credential_claim` and `credential_withdrawal` parse, reach the builder, and
get a transaction the chain refuses at `Mc2` — surfacing as `400 ScriptRefused` naming `Mc2`. This is
finding **F9** (`onchain-flows.md:54, 302-309`), open.

**What is missing.** An off-chain refusal. The error constructor for it exists and is documented
(`AttestationKindIsCredentialBinding`, `Exceptions.hs:97-106`) but has **no throw site on this route**.
**Frontend action:** offer only the five presentational kinds in the picker —
`milestone_delivered`, `audit_passed`, `affiliation`, `role_held`, `endorsement` — and route the other
two to §2.2 / §2.3.

### G8. The published `GYAddress` description is wrong

**The screen needs** to send addresses in the form the API accepts.

**What exists.** The Swagger `description` says "Bech32-encoded Cardano address (addr_test1... on
testnet)". The parser is `deserialiseFromRawBytesHex`; `addr_test1…` is **refused**. The same
definition's `format: cbor hex`, `minLength: 114`, `maxLength: 114` and its hex example are all
correct.

**What is missing.** A corrected description. **Frontend action:** a CIP-30 wallet's
`getUsedAddresses`/`getChangeAddress` already return hex — use them as-is and do not bech32-encode.
A dev who follows the description will get a 400 on every single write.

### G9. The Swagger document does not declare the write routes' auth

**The screen needs** to know a route needs credentials.

**What exists.** Every write route is wrapped in `BasicAuth` (`interaction-api/RestAPI.hs:281-303`).
Measured: `401` with an empty body and no `code`. The generated document has
`securityDefinitions: null` and `security: null`, because it is generated from `PublicAPI`, which
deliberately excludes the auth wrappers.

**What is missing.** The security scheme in the document, and a JSON body on the 401. **Frontend
action:** the browser must never hold these credentials — put the interaction-api behind a BFF that
adds them server-side, which is also what spec §4.5 requires ("no provider keys in the bundle, a BFF
with a rate limit").

### G10. A committee credential cannot be verified in reverse

**The screen needs** the verify direction for a `Committee` profile: "given `cc_cold1…`, which profiles
claim it". This is the same screen as for a DRep, and committees are a named target audience (spec §2).

**What exists.** `/profiles/by-credential/{credential}` accepts **DRep ids only**. Measured live:

```
GET /profiles/by-credential/cc_cold1zgqn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32q0e9tgc
→ 400 {"code":"invalid_drep_id","message":"Not a DRep identifier"}
```

The handler calls `canonicalDrepCredential`, which is `parseDrepIdAny`, which requires the HRP
`drep` (`query-api/Query/Attest.hs:121-125`; `DomainTypes/Core/Ids.hs:97-111`).

**What is missing.** A reverse lookup for `cc_cold1…` and `cc_hot1…`. This is not a parsing nicety: ADR
0006 made all three roles claimable precisely so a committee's claim would be verifiable, and the write
path accepts them today — so the registry can hold a claim that no route can resolve. There is no
workaround through `/attestations` either: that route has no `credential` filter
(`Transfer/Filters.hs:460-466`), and the derived `credential` column on `/profiles` has no filter of
its own exposed as a query parameter.

### G11. A script claim needs a second signature with no route for it

**The screen needs** a multisig organization or committee to complete a credential claim. Per spec §2
this is the **majority** case, not an edge case.

**What exists.** `/claim-credential` returns **one** unsigned transaction. `/submit-tx` takes
`{tx_unsigned, tx_wit}` — a single witness set.

**What is missing.** Nothing in the API collects or merges a second witness, and nothing persists a
half-signed transaction between sessions. The frontend must do all of it client-side: hold the unsigned
CBOR, collect *n* witnesses out of band, merge them into one witness set, and submit. The same gap is
recorded on the admin side as finding **F2** — `admin rotate-admin` builds a transaction requiring the
incoming admin's signature and then signs with one key, so "a real handover cannot complete through the
CLI" (`onchain-flows.md:47`). The write API has the identical shape of problem for every script
claimant.

### G12. "Is this attestation contested?" costs N requests on a list

**The screen needs** a dispute badge on each row of a track record or an attestations list.

**What exists.** `GET /attestations/{id}` inlines up to 50 disputes — excellent for a detail page, and
the right call ("a client that fetches the challenges separately will render the attestation before
they arrive"). `GET /disputes?target=<id>` is the paged view, one attestation at a time.

**What is missing.** No `disputed` boolean on `AttestationRow`, no `dispute_count`, and no way to ask
`/disputes` about a *set* of targets. A 50-row track record needs 50 detail requests, or one
`/disputes` sweep the client joins itself — and `/disputes` has no `target IN (…)` filter, so the sweep
is "page everything and filter locally".

### G13. No "disputes I opened" and no verdict filter

**The screen needs** a disputer's own history, and "show me upheld findings".

**What exists.** `DisputeFilter` has exactly two fields: `target` and `resolved`
(`Transfer/Filters.hs:487-489`). `resolved` is `verdict IS NOT NULL`, which lumps `upheld`, `rejected`
and `expired` together — and the DTO's own description warns that a client wanting findings only must
read the verdict value, not the flag.

**What is missing.** `opened_by` and `verdict` as query parameters. There is also no
`/disputes/{dispute-id}` detail route at all (confirmed against the Swagger `paths`), so a dispute is
only reachable through its target attestation or by paging the whole list.

### G14. No "attestations I issued that are still pending"

**The screen needs** an issuer's outbox: what have I claimed that nobody has countersigned?

**What exists.** `GET /attestations?issuer=<id>&accepted=false` does exactly this — **per profile**.

**What is missing.** Nothing, *if* the UI knows its own profile ids. It does not (G1). The two gaps
compound: every wallet-side list in the product is blocked on the same missing piece.

### G15. Profile metadata has no editable-field contract

**The screen needs** an edit form that submits only what changed.

**What exists.** `/update-profile` requires `image_uri` even when it is unchanged, and treats an
omitted `description` as "keep the current one". So the form must pre-fill `image_uri` from a prior
`GET /profiles/{id}`, and a stale read silently rewrites the image to an old value.

**What is missing.** Either `image_uri` made optional with the same keep-current semantics as
`description`, or a documented read-then-write contract. There is also no `updated_at` or revision
field, so the UI cannot detect that someone else edited the profile between the read and the write, and
cannot distinguish a projected no-op edit from an edit that has not landed yet.

### G16. Two documentation residues a dev will trip on

**`/claim-profile`'s published description still documents a `credential` field it no longer has.** The
route's Swagger text, the request schema's description and a `describeField "credential"` for a
property that does not exist all survive ADR 0003 (`onchain-flows.md:223-228`). A client reading the
published document will send fields the route ignores.

**`onchain-flows.md` §3.7 is stale about `deposit_to`.** Its table says "default = `change_address`" and
finding F4 says `Md8` has no off-chain mirror. Both were true and are not: `Interactions.hs:167-178`
passes the field through undefaulted so the *builder* can default it to the user-token address, and
`Exceptions.hs:36-55` is the off-chain mirror, shipped as `DepositAddressNotSpendable` /
`DepositAddressIsScript`. **Trust the Swagger text and `ServiceRequests.hs:249-266` over §3.7** on this
one field.

---

## 7. What this document could not establish

- **UNVERIFIED: live response bodies for the attestation read routes.** The running deployment's
  projections are empty (`GET /profiles?limit=2` → `{"items":[],"total":0,…}`) and `GET /status`
  reports `attestation: null` — no projector is running against this database. Every response **shape**
  in §2.10 is taken from the query-api Swagger `definitions`, which is generated from the same types the
  handlers return, and from the field names the handlers and DTOs declare in source. No real populated
  row was read, and no example response body in this document is a live capture.
- **UNVERIFIED: the exact trace-code → message text** for the `ScriptRefused` arm. The codes are parsed
  out of the rendered Plutus failure (`Exceptions.hs:325-341`) and the format is
  `"A validator refused this transaction: <codes>. …"`, but no refusal was triggered against the live
  service, because doing so means POSTing a transaction.
- **UNVERIFIED: the on-chain codes `Mda` and `U0`/`U1`** are named in `onchain-flows.md` but their
  exact conjunct text was not read in the validator sources.
- **UNVERIFIED: whether `attestation.credential` is published on an `AttestationRow` for the five
  ordinary kinds.** The DTO declares the field optional and the on-chain rules (`Mc2`/`Mc4`) require it
  present on a credential record and absent elsewhere, so it should be `null` on the other five — but
  no populated row was available to confirm the projection does that.
