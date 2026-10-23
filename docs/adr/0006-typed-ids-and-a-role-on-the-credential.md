# ADR 0006 — Typed ids, a role on the credential, and no lineage

Status: accepted 2026-10-24, owner's decisions, closing audit findings `OC-04`, `OC-05` and `OC-08`
Date: 2026-10-24

## Decision

Three changes to the datum format, taken in one window because every one of them moves the script
hashes and the window closes at the first deployment anyone keeps.

1. **`attestationCredential :: Maybe ClaimedCredential`** — the claimed credential carries the
   governance role it is claimed under (`ClaimedDRep` | `ClaimedCCCold` | `ClaimedCCHot`, indices
   0-2). `OC-04`.
2. **One CIP-67 label per kind** — profiles keep 100/222; an attestation reference token takes
   **private-use label 1** (`0x00001070`) and a dispute reference token **label 2** (`0x000020e0`).
   `Mg` requires a profile id on both sides, `Md4` an attestation target and a profile opener, and a
   new rule `Mr` refuses a self-issued attestation. **Lineage is dropped.** `OC-05`.
3. **`OnchainProfile.profileOracleToken :: AssetClass`** replaces the whole embedded
   `ProtocolParams` record. `OC-08`.

## `OC-04`: a committee cold key was published as a DRep

CIP-129 puts the role in a header byte: `(keyType << 4) | kind`, so DRep is `0x22`/`0x23`, committee
cold `0x12`/`0x13`, committee hot `0x02`/`0x03`. The datum stored a bare `Credential` — 28 bytes plus
a key-or-script flag and nothing else — so the header was discarded at parse time and the renderer
had to guess. It guessed `drep` for everything.

A `Committee` profile claiming `cc_cold1…` was therefore **published as `drep1…` of the same bytes**:
an identifier that resolves to nothing in GovTool or db-sync, so a reader could not verify the claim
they were being shown. The proof rule was always sound. The record was lossy.

The old justification — "which governance role those bytes play is the profile's `kind`" — is wrong
twice. An `Organization` may be a DRep, a `Committee` may hold both committee credentials, and
nothing on chain ties `OnchainProfileKind` to either.

`ccColdIdCip129` and `ccHotIdCip129` already existed; only the dispatch was missing. **All three
roles are claimable, the hot one included.** Without ADR 0003 that would be an argument against it —
a record pointing at a rotated hot key is misinformation with a timestamp — but the claim/withdrawal
chain already handles rotation, so excluding it would remove a capability and fix nothing. Stake
credentials remain unclaimable and always were, whatever the Haddock said: `parseCredentialCip129`
never accepted one, and control of a stake credential is proved by a withdrawal in `txInfoWdrl`
rather than by a spend.

A withdrawal must now name the same **role** as the claim it supersedes. That is the right rule
rather than a side effect: withdrawing a DRep claim has no business cancelling a committee-cold one
over the same 28 bytes.

## `OC-05`: ids were untyped, and lineage was the only reason to leave them that way

Every id was `label 100 ‖ blake2b_224(seed)` under one policy, so `Mg` and `Md4` could only ask "is
this a reference-prefixed token of this policy". Three classes of permanent garbage followed:

* `subject` could be an attestation id or a name never minted. The record mints, can never be
  accepted — `A5` wants a user token `handleNewAttestation` does not create — and can never be
  removed, because nothing in this protocol burns.
* `subject == issuer` passed, and `Mf` and `A5` both read `valueSpent`, so the one user token
  satisfied both: an `AuditPassed` or `Endorsement` by X about X landed as an **accepted** record
  with no second party in the transaction.
* A dispute could target a profile, another dispute, or a name never minted, and the projection
  column `targetAttestationId` would then point at a non-attestation.

None of it forges a record. All of it is clutter a four-byte check prevents.

**Why a label and not a discriminator byte.** A token name is at most 32 bytes and an id is already
`4 + 28` — exactly 32. There is no room for a byte without shortening the hash, but the four bytes
already spent on a label can carry the kind for free.

**Why private-use labels.** CIP-67 reserves 0-15 for private use, which is the spec's own answer for
a protocol that needs its own classes, and the policy id already scopes every check here. Profiles
keep 100/222 because a profile genuinely **is** a CIP-68 pair — it has a user token and a wallet
should see it as one. An attestation and a dispute have none, so squatting CIP-68's labels would tell
every wallet that reads labels to go looking for a 222 that does not exist.

Both checksums were computed with CIP-67's own CRC-8 and **verified by reproducing all four
registered CIP-68 labels (100, 222, 333, 444) with the same encoder before trusting it on a new
one.** A wrong checksum is a label every CIP-67 reader rejects, and it would have been frozen into
every id this protocol ever mints.

### Lineage is dropped, and the audit's own fix text would have broken the protocol

The audit offered `Mg` the union "profile ∪ attestation" to keep lineage — an attestation about an
earlier attestation — possible. The owner dropped the feature on 2026-10-24, which makes the rule
simpler: the union existed only to permit a non-profile subject.

Dropping it is also the honest call, because **lineage never worked.** `A5` asks the subject to spend
the user NFT derived from its id, and an attestation mint creates no user token, so a lineage record
was `isAccepted = False` for as long as the chain existed — and the read layer is under instruction
to present that as "pending", to a subject who could not act. The emulator case that asserted this
(`5.11b`) is the evidence; it has been replaced by the refusal.

And the audit's `Mr` as written would have **bricked every credential record**. `Mc1` *requires*
`subject == issuer` on a `CredentialClaim` and a `CredentialWithdrawal` — a binding is self-issued by
construction — so a literal `subject /= issuer` contradicts it. ADR 0003 landed after the audit, so
its fix text was written against a protocol that no longer existed. `Mr` exempts the credential
kinds, and `isCredentialKind` was already in the file to say which those are.

### The regression this change introduced, and how it was caught

`isUnbackedDatum` hardcoded `isRefTokenName`. That was correct only while every id wore label 100.
Once attestations moved to label 1 and disputes to label 2, the test read "this is not a label-100
name" — **true of every real attestation and every real dispute** — so `A4` and `D8` would have
declared the entire protocol's state sweepable, and `Cleanup` is permissionless.

The signature was unchanged and the code compiled. It was caught by reading the callers of the
predicate the labels changed; the emulator's "Cleanup CANNOT spend real protocol state" case would
have caught it too, which is what that case is for. `isUnbackedDatum` now takes the kind's own name
predicate, which is **strictly stronger** than the old form: a dispute datum parked at the
attestations address is unbacked there however well its own value backs it.

## `OC-08`: params nobody read, in every profile ever minted

`OnchainProfile.protocolParams` was the whole `ProtocolParams` record and exactly one of its four
fields was ever read off a profile datum — `ProfilesValidator` took `oracleToken` and nothing else.
The three validator script hashes rode along unread, and the minting policy already has them as its
compile-time parameter, which is where a validator address belongs.

Pinning the oracle token in the datum is unchanged and still right: it is what stops a forged oracle
UTxO being substituted at spend time, the same reason `disputeOracleToken` and
`attestationOracleToken` exist.

## Consequences

* **The datum format changed, so the hashes moved.** One redeploy at the end of this window, not one
  per change.
* **`OC-08` paid for more than half of `OC-04`.** Measured: `OC-04` cost +298 bytes across the
  protocol, `OC-08` refunded 177, for +121 net. Taking the correctness fix alone would have cost the
  full 298. That is what "the same format window" is worth in bytes rather than in prose.
* **Two zeros in the size table are an assertion, not an absence.** The Disputes validator and the
  Oracle read neither datum and neither moved — which confirms that the profiles validator was the
  only reader of a profile datum's embedded params, and that the credential wrapper is paid only
  where an attestation datum is parsed.
* **A client that derives ids itself must now know the kind.** `gyGenerateAttestationAC` and
  `gyGenerateDisputeAC` mirror the policy's own derivations; a disagreement shows up as `Mj`
  refusing the mint rather than as a wrong id in the registry.
* **Noticed and deliberately not touched:** `LineageGraphData`/`LineageNode` in `QueryResponses.hs`
  have no users outside their own module. They model a graph of **profiles** — the Belt System's
  sense of the word — not attestations about attestations, so this ADR does not make them dead; they
  were already.
