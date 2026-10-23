# ADR 0005 — The admin is a `Credential`, and the arbiter is a second one

Status: accepted 2026-10-24, owner's decision, closing audit findings `OC-01` and `OF-01`
Date: 2026-10-24

## Decision

`OracleParams` holds **two credentials** where it held one key hash:

```haskell
opAdmin   :: Credential   -- was opAdminPkh :: PubKeyHash. Parameters, pause, fees, rotation (O1).
opArbiter :: Credential   -- new. Dispute verdicts, and nothing else (D1).
```

Both are proved with `Utils.checkCredentialControl`, which reads a key credential as a signature and
a script credential as a spent input at its own address. Both are rotatable — `OracleSetAdmin` at
redeemer index 4, `OracleSetArbiter` appended at 7 — and `O5` now covers both handovers.

Genesis sets the two to the same `PubKeyCredential`, so a deployment that never splits them behaves
exactly as one field would.

## Why a `Credential` and not a `PubKeyHash`

The owner's question was the right one: *can we start on one key and move to a multisig later?*

With `PubKeyCredential`, `O1` is `elem pkh txInfoSignatories` — **byte-for-byte what the protocol did
before**, so day one changes nothing. With `ScriptCredential`, the same rule accepts a spent input at
the script's own address, which a native multisig satisfies by being spent, with no ExUnits and no
Plutus. So "start simple, upgrade later" is a rotation, not a redeploy.

A `PubKeyHash` is precisely what forecloses that. It cannot name a script, so the upgrade would have
needed a new datum format — and after a kept deployment, a new datum format is a new registry
(`OC-09`). **Not taking this change was the decision that locked the protocol to one key forever**,
which is why it had to be taken before the first deployment anyone keeps.

What it buys, concretely, against the two halves of `OC-01`:

* **Key loss.** Today a lost admin key means `O1` refuses every future update including the rotation
  that would fix it, so the protocol can never be unpaused, repriced or re-keyed, and `D1` can never
  be satisfied, so every open dispute's 5 ADA deposit is locked forever. A 2-of-3 native multisig
  turns that from an ending into an inconvenience.
* **Key compromise.** An attacker with the one key can set `fcFeeAddress` to themselves at any
  amount — and the API builds whatever the oracle prices, so users signing in their wallets pay it —
  raise `opMinUTxOValue` to grief every mint, write arbitrary verdicts beside true records, and
  rotate the admin to themselves. A multisig needs n of them.

## Why not an authority NFT

The alternative the owner raised, and it is a reasonable instinct: a token admin makes handover a
plain send, with no `O5` dance and no protocol transaction.

That convenience is exactly the property you do not want at the root of trust.

* **It is the failure mode this protocol already records elsewhere.** `OC-03`: authority tokens can
  be locked inside state outputs, and one `UpdateProfile` that parks the user NFT in the state output
  makes a profile permanently world-writable. Adopting a bearer token as the root means adopting that
  class of bug at the root.
* **Loss gets worse, not better.** An HD-wallet key is recoverable from its seed phrase. A token sent
  to a wrong address, or into a contract with no exit, is not — and there is no notion of "the real
  admin" left to appeal to.
* **Phishing becomes identity transfer.** `OC-10` is already documented: consent to a transaction is
  not consent to the token's destination. With a key, signing a malicious transaction cannot transfer
  adminship. With a token it can, once, irreversibly.
* **Every action pays.** `txInfoSignatories` is free. A token must be spent and returned every time:
  min-ADA, an extra input and output, and a contention point where two concurrent admin actions
  collide. `D1` would pay it on every verdict too.
* **`O5` would be gone**, and `O5` is a safety feature: a mistyped address would brick the protocol
  with no second side to check.

And it is not a trade-off we have to make, because **`ScriptCredential` can point at a script whose
rule is "whoever spends the admin NFT".** This shape contains the token design as one of its cases;
the token design cannot express a plain key without paying the token's costs. If that convenience is
ever wanted — with a timelock or a second signature as guardrails — it is a small Plutus script and
no datum change.

## Why the arbiter is a second field

With one credential, `D1` reads what `O1` reads. So putting the admin in a cold multisig makes
**every dispute verdict** cost that multisig a UTxO spend, because proof of control for a script is a
spent input. Setting parameters is rare and catastrophic to get wrong; writing verdicts is
operational and repeated. One credential forces one key hygiene on both.

The field costs nothing to anyone who does not want it: genesis sets `opArbiter == opAdmin`, and
`admin query-oracle` prints which of the two states a deployment is in rather than leaving it to be
inferred. Not adding it would have closed the split forever, for the same datum-format reason as
above — the same asymmetry that decided the field above it.

It is rotatable because an unrotatable arbiter is `OC-01` reintroduced over the half of the protocol
that holds **other people's money**: lose the credential and no dispute can ever be resolved, so
every open deposit is locked.

## `OF-01`: the rotation that could not rotate

`O5` requires the incoming side to prove control in the same transaction the outgoing admin
authorises. `rotate-admin` built, signed with one key and submitted in one step, so it produced a
transaction the chain refuses by construction — the audit's `OF-01`, and the reason this ADR and that
finding are one change.

Two primitives were missing, and both are thin because the pieces existed:

| piece | what it reuses |
| --- | --- |
| `buildActionWithPK` | `interactionToHexEncodedCBOR`, the same hex the write routes hand a wallet |
| `submitSignedTxWithWitnesses` | `appendWitnessGYTx` + `signGYTx` from Atlas |
| `admin sign-tx` | already existed, already prints witness hex; gained `--key-file` |

So the flow is:

```
current admin:   admin rotate-admin --new-credential <hash> [--script] --build-only > tx.hex
incoming side:   printf '%s' "$(cat tx.hex)" | admin sign-tx > incoming.wit
current admin:   admin submit-tx --tx tx.hex --witness incoming.wit
```

`submit-tx` takes the transaction rather than rebuilding it, and that is load-bearing: a witness
signs a **body hash**, so a rebuild of the same action can select different inputs and invalidate
every signature already collected.

`sign-tx` gained `--key-file`, defaulting to `operation.prv`. The default is right for the normal
case — the incoming side is a different person on a different machine with their own key. It was
wrong for the one-machine case, where the only way to sign as the other party was to move
`operation.prv` aside and put another key in its place: a manual file swap around the one file that
controls the protocol, which `new-operator-key` already refuses to overwrite for the same reason.

The flagless `rotate-admin` now **refuses** and names those three commands, instead of submitting
something doomed. An error that says what to do next costs one message; a transaction that turns out
to be unsubmittable costs a fee and an investigation.

## The runbook line that is easy to miss

**Fund the incoming multisig before rotating to it.** `checkCredentialControl` proves control of a
script by finding a spent input at its own address, so a script that holds no UTxO cannot prove
control at all — the limitation its own Haddock already records for credential claims. Send the
multisig address a UTxO first, then build the rotation with `--incoming-witness`.

## What is deliberately not done

* **A script arbiter cannot resolve a dispute over HTTP yet.** `ResolveDisputeAction` would need an
  optional witness field. That is a JSON field, and optional, so adding it later breaks no client —
  unlike the datum format, which is why the datum half is taken now and this half waits for someone
  who needs it. A script arbiter can resolve through the admin CLI today.
* **The other six admin commands assume a key admin.** Only `rotate-admin` and `rotate-arbiter` take
  `--admin-witness`. Wiring the same flag into pause, unpause and the four setters is mechanical;
  rotation is the one that could not wait, because it is how you get back to a key.
* **No threshold logic on chain.** "2 of 3" is the native script's business, which is the point of
  pushing it into a credential rather than modelling it in the datum.

## Consequences

* **The datum format changed, so the hashes moved.** The preprod deployment of 2026-10-23 is dead,
  which is what it was for.
* **`O5` is no longer a signature check** but a proof-of-control check, on both handovers.
* **`query-oracle` prints both credentials** and says in words whether they are split, because the
  whole point of the split is that they *can* differ, so a reader must be able to see that they
  currently do not.
* **The admin's mainnet shape is now a deployment-time choice, not a code change** — which is the
  outcome the owner asked for.
