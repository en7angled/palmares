{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | What each validator costs to put on chain.
--
-- __The gap this closes.__ @TxBuilding.Validators@ has exported @profilesValidatorSize@ and its four
-- siblings since the first commit and nothing ever called them. The only place a size was ever
-- reported was a log line in @TestRuns.deployValidators@ — printed, never asserted, and for the
-- whole stretch while the emulator suite was dormant, never even printed. So a change that doubled a
-- script was indistinguishable from one that did not, right up to the deployment that paid for it.
--
-- __Two assertions, because they catch different things.__ The ceiling is correctness: a reference
-- script has to fit in a transaction, and one that does not cannot be deployed at all. The exact
-- table is economics: a validator that grew 30% still deploys, still passes every other test, and
-- quietly raises the min-ADA of every UTxO that references it. Pinning the number is what makes that
-- growth a visible diff instead of an invoice. When a change is meant to move a size, the table is
-- updated in the same commit — that update IS the record.
module UnitTests.ScriptSize (tests) where

import Palmares.TxBuilding.Validators
  ( attestationsValidatorSize,
    disputesValidatorSize,
    mintingPolicySize,
    oracleValidatorSize,
    profilesValidatorSize,
  )
import PlutusLedgerApi.V1.Value (AssetClass (..), CurrencySymbol (..), TokenName (..))
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "script sizes"
    [ -- The whole table in one assertion, so a failure prints every size rather than the first one
      -- that moved. Flat-encoded bytes, which is what goes in the reference-script output.
      testCase "every validator is exactly the size it was when this was last reviewed" $
        assertEqual "a validator changed size — update the table in the same commit, deliberately" expected measured,
      -- The hard limit. `maxTxSize` is 16384 bytes, and the transaction that deploys a reference
      -- script carries the script PLUS its own inputs, outputs, change and witnesses. 14000 leaves
      -- about 2.4 KB for all of that, which is the margin `deployValidators` actually runs in.
      --
      -- The MintingPolicy is the one to watch: at 12241 bytes it is 75% of a whole transaction, and
      -- it is the only script that grows when a redeemer case is added. The four spending validators
      -- sit between 7.6 and 8.4 KB and have room.
      testCase "every validator leaves room for the transaction that deploys it" $
        filter ((> 14_000) . snd) measured @?= []
    ]

-- | Measured sizes, by name. The minting policy is parameterised, so it is measured against a local
-- placeholder oracle token — a real deployment's 28-byte currency symbol adds a few bytes to this
-- figure and nothing structural.
--
-- This used to say "the same placeholder oracle token the blueprint uses". It no longer does: the
-- blueprint stopped shipping a compiled minting policy at all, because applying a placeholder meant
-- publishing a CIP-57 @hash@ field that matched no deployment. A measurement against a placeholder
-- is honest; a published hash derived from one is not, which is the whole difference between these
-- two uses of the same trick.
measured :: [(String, Int)]
measured =
  [ ("ProfilesValidator", profilesValidatorSize),
    ("AttestationsValidator", attestationsValidatorSize),
    ("DisputesValidator", disputesValidatorSize),
    ("OracleValidator", oracleValidatorSize),
    ("MintingPolicy", mintingPolicySize placeholderOracleToken)
  ]
  where
    placeholderOracleToken = AssetClass (CurrencySymbol "", TokenName "")

-- | Measured on 2026-10-21, GHC 9.6.6 with the frozen plutus-tx, at the end of Plan B's Phase 2
-- (five validators, disputes included) and with traces preserved — which is the default build and
-- therefore the one that gets deployed. A toolchain bump moves all five at once and is the one case
-- where updating this table wholesale is the right response.
--
-- With traces stripped the same five measured 7707, 7410, 8032, 7293, 11482 — taken before the
-- critical fix below, and not re-measured since, because the option to strip them is gone. Traces
-- cost between 1.8% and 3.4%, which is what made keeping them an easy decision.
--
-- Every move so far, and which validators did NOT move each time — which is the useful part of this
-- table, because an unchanged number bounds a change instead of describing it:
--
--   MintingPolicy 11871 -> 11850  deleting the staking-half disjunct from 'checkCredentialControl'
--                                 (one comparison fewer) when the first audit's critical finding
--                                 was fixed. The other four did not budge.
--   MintingPolicy 11850 -> 11865  adding the interval-WIDTH check to 'checkDateInRange' when the
--                                 second audit found that inherited fix #4 had closed containment
--                                 and left width open. The other four did not budge.
--
-- Both of those functions are reached only from the minting policy, which is exactly what the four
-- unchanged numbers said.
--
-- Then the dispute-family audit fixes, three validators in one commit:
--
--   DisputesValidator 8243 -> 8340  @D6@, one dispute resolved per transaction, which is what makes
--                                   @D4@'s `any` over the outputs sound
--   OracleValidator   7427 -> 7492  @O5@, a handover must carry the INCOMING admin's signature
--   MintingPolicy    11865 -> 11920 @Md4@ extended to the dispute opener's currency symbol, and
--                                   @Md8@, the payout address must be one the tx spends from
--
-- ProfilesValidator and AttestationsValidator did not move, and that is the assertion worth having:
-- the dispute fixes touched the dispute path, the oracle fix touched the oracle, and the shared
-- helper added to 'Palmares.Onchain.Utils' ('spentExactlyOnceFromAddress') is reached from exactly
-- one validator rather than linked into all five.
--
-- Then the mint-path redeemer checks, and this is the most expensive single change so far:
--
--   MintingPolicy 11920 -> 12241  @Mn@ ('validateOtherMetadata') and the CIP-67 reference-prefix
--                                 half of @Mg@ and @Md4@ ('isProtocolRefToken'). The other four did
--                                 not budge.
--
-- 321 bytes, and almost all of it is @Mn@: the duplicate-key check is a quadratic scan written as
-- two recursive functions, and recursion is what PlutusTx cannot share. It buys a bounded datum on
-- a record nobody can remove, so it is worth it — but it is the one line in this table where the
-- cost is worth looking at again if the policy ever approaches the ceiling. The prefix check is
-- four bytes of comparison reused at four call sites.
--
-- Then the three STATE validators, and the asymmetry is the interesting part:
--
--   ProfilesValidator     7879 -> 8381  (+502)  'Utils.isUnbackedDatum' on @Cleanup@, AND @P6@ —
--                                               which had to add an oracle read this validator did
--                                               not previously do at all
--   AttestationsValidator 7554 -> 7604  (+50)   'Utils.isUnbackedDatum' alone. No pause check: an
--                                               'OnchainAttestation' carries no oracle token, and a
--                                               token taken from the redeemer would be
--                                               attacker-chosen and therefore worthless
--   DisputesValidator     8340 -> 8424  (+84)   'Utils.isUnbackedDatum' and @D7@, which is one
--                                               boolean because the oracle was already bound in the
--                                               @ResolveDispute@ arm
--
-- +50 against +502 for the same shared helper is the whole cost of REACHING the oracle, measured.
-- It is also why the Attestations validator's pause is off-chain only: the cheap routes were taken
-- and the remaining ones change either the deployed datum format or every honest client's
-- transaction. OracleValidator and MintingPolicy did not move, which says the helper is reached
-- from exactly the three validators that call it.
--
-- Then the adversarial audit of 2026-10-22, and every number below is a check that was missing:
--
--   ProfilesValidator     8381 -> 8414  (+33)
--   AttestationsValidator 7604 -> 7637  (+33)
--   DisputesValidator     8424 -> 8457  (+33)
--
-- The same +33 three times, because 'Utils.isUnbackedDatum' grew the half it was written without:
-- it asked whether the datum's named NFT is in the input's value, but not whether that NFT is a
-- CIP-67 *reference* token. A planted datum naming a USER token answered "no NFT here" and was
-- therefore classified as backed state, which made it permanently unsweepable — free, irreversible
-- address clutter. Identical cost at all three sites because PlutusTx shares nothing between
-- scripts; each compiles its own copy of the four-byte prefix comparison.
--
--   OracleValidator       7492 -> 7547  (+55)  @O6@ ('oracleParamsAreWellFormed'). `geq` is
--                                              VACUOUSLY TRUE on a negative required amount — the
--                                              `These a b -> a >= b` arm is satisfied by anything
--                                              when b is below zero — so a negative
--                                              @opMinUTxOValue@ made every min-value check in the
--                                              protocol vacuous and drained ~3.8 ADA per dispute
--                                              from the admin's own wallet
--   MintingPolicy        12241 -> 12296  (+55)  @Mp6@ and 'Utils.valueAtOutputIdx'. @Mp5@'s `geq`
--                                              POSITIVELY PERMITTED the profile's user token inside
--                                              the state output; locked there, @P3@ was satisfied by
--                                              the profile's own input and any stranger could
--                                              rewrite that profile forever
--
-- 55 bytes each, and both are the same shape of bug: a @geq@ whose direction nobody re-read. Worth
-- the pattern: every size in this table that was NOT a feature was an inequality that permitted
-- more than its sentence claimed.
--
-- __THE SIZE AUDIT OF 2026-10-22, with the five items DECLINED and why.__ Recorded here rather than
-- left in a report, because a declined item that nobody wrote down gets re-proposed. The calibration
-- the audit worked from is this table's own history: a recursion is ~45-50 bytes, a comparison
-- ~10-20, and reaching the oracle ~450.
--
-- Applied: @validateOtherMetadata@ from six recursions to three (see 'validateOtherMetadata' for
-- the argument, and @UnitTests.MintInputs@ lines 92-122 for the nine cases that already pinned it).
-- Estimated at ~135 bytes from the calibration above. __MEASURED AT 20__, 12296 -> 12276, and the
-- gap is the more useful result.
--
-- Part of it is that one of the four removed traversals never left: @elem@ is still compiled into
-- this policy through 'Palmares.Onchain.Utils.checkCredentialControl', which is @INLINEABLE@ and
-- reached from the claim path, and @any@ with it. Worth recording how that was nearly got wrong —
-- grepping @MintingPolicy.hs@ for @elem@ finds nothing, because __the compiled script is the
-- inlined whole and not one file__. @all@, @map@ and the list @<>@ were genuinely unique to
-- 'validateOtherMetadata', so the net removal is about two fixpoints, which the ~45-each
-- calibration predicts at ~90 and which measured 20.
--
-- The calibration therefore over-predicts by about four even after that correction, and the honest
-- reading is that it was derived from INTRODUCING traversals into a script that lacked them and
-- does not invert. Treat every estimate below as an upper bound.
--
-- Keep the change for the ExUnits, which is where the real return is: three traversals instead of
-- six, no intermediate @map fst@ list built, and 168 key comparisons instead of 171.
--
-- Declined, in descending order of how tempting they are:
--
--   * @checkDateInRange@ without the @Interval@ library, ~150 bytes. The three new cases in
--     @UnitTests.OracleRules@ make this SAFE to do — they pin the exclusive-upper-bound semantics
--     the ledger actually delivers — but there is no reason to do it. This is the only function
--     that dates a permanent record, and ~1700 bytes of headroom is not a reason to hand-roll
--     library semantics.
--   * @and [...]@ to @&&@ in ProfilesValidator and OracleValidator, ~90 bytes. Those lists hold the
--     @traceIfFalse@ calls, and a strict list forces all of them, so a failing transaction logs
--     EVERY failing code; @&&@ logs the first. That is a diagnostic trade, and this project already
--     took the opposite decision explicitly when it chose @preserve-logging@ over @remove-trace@ in
--     the cabal file. The AttestationsValidator and DisputesValidator sites are different — their
--     @and@ sits inside a single @traceIfFalse@, so converting them changes no diagnostics — but
--     ~90 bytes on scripts with 8 KB of headroom is not worth a diff.
--   * @valueSpent@ to a shared @inputsSpendExactlyOne@. Measured at ~0 on the minting policy: it
--     removes one @foldMap@ recursion and adds the helper's own, and does not remove @unionWith (+)@
--     because the policy sums @Value@s anyway. This project's +50-against-+502 lesson, in reverse.
--   * @checkFee@ computing @feeFor@ once, 0-20 bytes. All three call sites pass a known constructor,
--     so it very likely constant-folds already. It also needs parentheses rather than @$@ to
--     compile, since @$@ is @infixr 0@ against @||@'s @infixr 2@.
--   * @MintingContext@ removal, 0 bytes. The record is built once and field-selected in the same
--     compilation unit, so case-of-known-constructor eliminates it before UPLC is emitted. Removing
--     it could make the policy LARGER, because passing three arguments to three handlers is more
--     binders than one record.
--
-- __The trace-code splits of 2026-10-22, which cost 3 bytes in total.__
--
--   AttestationsValidator 7637 -> 7640  (+3)  @A1@ split into @A1@/@A5@/@A6@
--
-- The three renames cost NOTHING, which is the useful part: @P0@->@P7@, @A0@->@A4@, @D0@->@D8@ and
-- @Ml@->@Mq@ are all two characters for two, so a clearer code is free whenever the old one was the
-- same width. Only the @A1@ split added anything, and even there the two new trace strings were
-- nearly paid for by dropping the @and [...]@ list those three conjuncts used to sit in — which is
-- the Attestations half of the audit's declined item 3, landed here as a side effect and no longer
-- a diagnostic trade, because each conjunct now reports its own code instead of all three reporting
-- @A1@.
--
-- Worth the lesson for the next time a code reads badly: diagnostics at this scale are not priced in
-- bytes. They are priced in whether anything is deployed, because a trace code becomes an operator's
-- runbook entry the moment something is.
--
-- Still declined from the earlier round, unchanged: @unsafeFromBuiltinData@ on the oracle read
-- (450-850 bytes across three scripts). It trades @K1@ — the only diagnostic on the only path that
-- reads external state — for bytes. It is the first lever if the policy ever approaches 14000.
--
-- __D-C: the pause reaching the acceptance.__ This table had already priced it, two rounds before
-- the decision — "+50 against +502 for the same shared helper is the whole cost of REACHING the
-- oracle, measured" — and that sentence is why the entry above said the attestation pause was
-- off-chain only.
--
--   AttestationsValidator 7640 -> 8134  (+494)  @A7@, and with it this validator's FIRST oracle
--                                               read: `readOracleParams` through the new
--                                               'Palmares.Onchain.Protocol.Types.attestationOracleToken'.
--                                               The pause check itself is one boolean; the 494 is
--                                               the read.
--   MintingPolicy        12276 -> 12310  (+34)  writing that field into the attestation datum from
--                                               @ctxOracleToken@
--
-- +494 here against the ProfilesValidator's +502 for the same thing, on a different validator and
-- two rounds apart: the closest this table has come to predicting a later measurement instead of
-- describing an earlier one. (It is a description from which ~452 is inferable, not a prediction
-- anyone wrote down in advance — an audit called that out and it is fair.)
--
-- ProfilesValidator and OracleValidator did not budge, which is the useful half: neither reaches
-- this attestation path. The first draft of this sentence named DisputesValidator and
-- OracleValidator and claimed their stillness showed "the oracle read is reached from exactly the
-- three validators that call it" — but DisputesValidator IS one of those callers, so its stillness
-- shows nothing about the caller set, and the MintingPolicy, also a caller, moved in this very
-- round. The sentence this copied got it right by naming two NON-callers.
--
-- __The datum field is not free beyond the script, and this is the part that is not in bytes of
-- code.__ An 'AssetClass' is a 28-byte currency symbol plus a token name, so every attestation's
-- inline datum grows by roughly 45-70 bytes of CBOR, and the LEDGER's min-ADA floor for that UTxO
-- rises with it: at @coinsPerUTxOByte@ = 4310 that is about 0.2-0.3 ADA per record, paid once, by
-- whoever issues the attestation. Whether a given @opMinUTxOValue@ still clears the new floor is a
-- deployment question and not a property of this table — the oracle's value is a configured
-- minimum, and the ledger's is the real one.
-- __D-A: the dispute exit that needs no key.__ The first change in this table to move all FIVE
-- scripts, and the two numbers nobody would have predicted are the interesting ones.
--
--   DisputesValidator  8457 -> 9401  (+944)  almost all of it the @ExpireDispute@ arm — ~30 is the
--                                            sixth 'OracleParams' field, the same ~30 the two lines
--                                            below pay, because this script decodes that record
--                                            too, and a little more is the wider 'OnchainDispute'.
--                                            The arm itself: @D3@, @D9@
--                                            ('Utils.checkDateHasPassed' — this script's first use
--                                            of the @Interval@ library, which is the single largest
--                                            term) and a SHARED call to @D2@/@D4@/@D6@.
--
-- __Shared, measured, and the first draft of this entry had it backwards.__ It said "PlutusTx
-- inlines it at both call sites, so the arm pays for its own copy either way" — an assertion, in a
-- table whose own best line is "MEASURED AT 20 ... and the gap is the more useful result". An audit
-- called that out, so it was measured the way the audit proposed: replace the ResolveDispute arm's
-- @&& disputeClosesWith …@ with @&& True@, rebuild, restore.
--
--   both call sites   9439
--   one call site     9415   (-24)
--
-- Twenty-four bytes for a call site that carries a whole-datum comparison, an @any@ over the
-- outputs and a counting traversal of the inputs. So the body is compiled ONCE and 24 bytes is the
-- application of five arguments: 'disputeClosesWith' did not merely buy source-level agreement
-- between the two ways a dispute closes, it also cost far less than duplicating the three
-- statements would have. The justification was correctness; the bytes went the same way by luck,
-- and saying so required a build rather than a belief.
--   OracleValidator    7547 -> 7688  (+141)  one more field in 'OracleParams'. @O2@ compares the
--                                            whole record and @O6@ checks it, so a field costs here
--                                            twice over.
--   MintingPolicy     12310 -> 12393  (+83)  @ctxDisputeTimeoutMs@, the @disputeStaleAfter@
--                                            arithmetic, and the wider 'OracleParams' decode.
--   ProfilesValidator  8414 -> 8444  (+30)   NOTHING in this change touches the profiles path.
--   AttestationsValidator 8134 -> 8163 (+29) Nor the attestations path.
--
-- Those last two are the measurement worth keeping: both validators DECODE 'OracleParams' — @P6@
-- and @A7@ read @opPaused@ — so adding a sixth field to that record costs ~30 bytes in every script
-- that parses it, whether or not it reads the new field. A record on the oracle is not free to
-- extend; it is ~30 bytes times the number of SCRIPTS that decode it, which is five: the three
-- state validators, the minting policy (whose entry above says it paid for the wider decode) and
-- the OracleValidator itself, which pays twice over because @O2@ compares the whole record and @O6@
-- checks it. The first draft of this line said "four validators", which needs an unstated reading
-- in which the minting policy is not one. The 2026-10-22 audit's calibration had no line for any of
-- this.
--
-- __And a per-USE price this table has never recorded.__ It prices size as deploy-time min-ADA on
-- the reference UTxO plus the 14000 ceiling. Under Conway a transaction that USES a reference script
-- also pays @minFeeRefScriptCoinsPerByte@: at the base tier of 15 lovelace per byte — a protocol
-- parameter, worth re-reading from the live pparams rather than trusting this line —
-- DisputesValidator's 9401 bytes are ~0.141 ADA on every dispute-closing transaction, and this
-- round's +944 adds ~0.014 ADA to each one, forever. It changes no verdict here, the headroom being
-- unchanged, but "has headroom" and "is free" are different claims and only the first was asserted.
--
-- __D-E: a credential claim gains a revocation.__ One script moved, which is the whole report:
--
--   ProfilesValidator 8444 -> 8759  (+315)  the @RevokeCredential@ arm. Most of it is
--                                           'Utils.checkCredentialControl', which until now was
--                                           compiled into the MINTING POLICY alone (@Mp3@) and is
--                                           now compiled into this validator too — PlutusTx shares
--                                           nothing between scripts, so the second user of a helper
--                                           pays full price for it. The arm's own statements reuse
--                                           @P2@ and @P5@ and add two Maybe matches.
--
-- The other four did not budge, and that is the assertion worth having: a revocation is reached
-- from exactly one validator, and nothing about it leaked into the oracle or the policy.
-- __The audit response.__ Three independent audits of D-C/D-A/D-E — vulnerabilities, cost, and
-- whether the new comments are true — moved one script:
--
--   DisputesValidator 9401 -> 9439  (+38)  @Da@, which refuses a RESOLUTION naming 'VerdictExpired'
--                                          (the arm takes `Verdict` as an unconstrained redeemer
--                                          argument, so appending a third constructor had handed
--                                          the admin an expiry with no clock), and the two
--                                          @!ownInput@ bangs. The bangs are byte-neutral by
--                                          themselves and were taken for a different reason: the
--                                          binding is impure, so `StrictifyBindings` refuses it and
--                                          without a bang each of the four derived values re-runs a
--                                          `find` over an attacker-sized input list.
--
-- The cost audit's verdict on the three new arms was "nothing material" — 30-80 bytes against 4,599
-- of headroom on the script that grew most — and its one actionable item was not an optimisation but
-- the measurement recorded above.
-- __ADR 0003: a credential claim becomes an attestation.__ The net is NEGATIVE, which is the part
-- worth recording: the cleanest variant is also the cheaper one.
--
--   ProfilesValidator     8759 -> 8355  (-404)  the @RevokeCredential@ arm went, and with it this
--                                              validator's only call to
--                                              'Utils.checkCredentialControl'. Almost exactly the
--                                              +315 D-E paid two entries up, plus the arm's own
--                                              statements — the table's first measured REFUND.
--   MintingPolicy        12393 -> 12618  (+225)  @Mp3@ left the profile path, but
--                                              `checkCredentialControl` stayed (it is @Mc3@ now),
--                                              the four @Mc@ rules arrived, and the attestation
--                                              datum got a field. Net cost of moving the rule.
--   AttestationsValidator 8163 -> 8293  (+130)  nothing about this validator's RULES changed; it
--                                              decodes one more 'Maybe Credential' in every
--                                              attestation datum it reads. The same shape as the
--                                              ~30-per-script 'OracleParams' lesson, at a larger
--                                              number because a Maybe of a Credential is a bigger
--                                              decoder than an Integer.
--   DisputesValidator     9439 -> 9439   (0)    and
--   OracleValidator       7688 -> 7688   (0)    neither touches profiles or attestations.
--
-- -404 +225 +130 = __-49 bytes across the protocol__, for a binding that no redeemer can erase and
-- a withdrawal that appends instead of deleting. The two zeros are the assertion worth having: a
-- change this wide reached exactly the two scripts that handle profiles and attestations.
--
-- __The zero-byte change that still moves a hash.__ An audit reconciliation found that
-- 'oracleParamsAreWellFormed' admitted @opDisputeTimeoutMs = 0@ — the exact value the comment beside
-- it argues against — so the conjunct went from @>= 0@ to @> 0@:
--
--   OracleValidator       7688 -> 7688   (0)
--
-- Zero because one builtin was swapped for another of the same size, and the table says so rather
-- than staying silent: a size that does not move is not the same claim as a script that does not
-- move. The BYTES differ, so the hash differs, so @ProtocolParams@ and the minting policy's hash
-- differ — which costs nothing today and would cost a redeployment after T-ATTEST-10. That is the
-- whole reason this correction was made now and not filed.
expected :: [(String, Int)]
expected =
  [ ("ProfilesValidator", 8355),
    ("AttestationsValidator", 8293),
    ("DisputesValidator", 9439),
    ("OracleValidator", 7688),
    ("MintingPolicy", 12618)
  ]
