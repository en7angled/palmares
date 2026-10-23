{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | Attestations, in a real ledger: issuance, the subject's counter-signature, and the four ways a
-- transaction can pretend to be one.
--
-- __This module was inherited from the Belt System and is rewritten, not ported.__ Its cases named
-- @CreateProfileWithRankAction@, @InitProfileAction@ and a belt enum that exists nowhere in
-- @src/lib@; what survived is the shape of the lifecycle, because the lifecycle is the same shape:
-- somebody issues a record about somebody else, and the subject decides whether it counts.
--
-- __Three of the negatives need a malicious builder and one deliberately does not__, and the
-- difference is the whole point of writing them down:
--
--   * @A3@ (double accept), @Ml@ (the recorded date) and @Mf@ (the issuer's user token) are
--     unreachable through 'Palmares.TxBuilding.Operations': it refuses the first off chain, derives
--     the second from the chain tip so a client cannot set it at all, and looks the third up in the
--     caller's own addresses. A @mustFail@ on those refusals would pass with the on-chain check
--     deleted, which is the mistake 'UnitTests.Oracle' documents for @O1@.
--   * the pause, the reserved metadata key, the missing subject and the wrong accepter are refused
--     __at skeleton-build time__, before any script runs. Those use plain 'mustFail' and say so:
--     naming a trace code there would assert nothing, because there is no trace.
module UnitTests.Attestation
  ( attestationTests,
  )
where

import Control.Monad (void)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Stack
import GeniusYield.Test.Clb
import GeniusYield.Test.Utils
import GeniusYield.TxBuilder
import GeniusYield.Types
import Palmares.DomainTypes.Core.Actions
import Palmares.DomainTypes.Core.Types (AttestationType (..), ProfileType (..))
import Palmares.Onchain.CIP68 (extra)
import Palmares.Onchain.Protocol.Types qualified as OnchainTypes
import Palmares.TxBuilding.Context (DeployedScriptsContext, getMintingPolicyFromCtx)
import Palmares.TxBuilding.Conversions (profileDataToMetadataFields)
import Palmares.TxBuilding.Lookups (getAttestationDatumAndValue)
import Palmares.TxBuilding.Skeletons (gyGenerateRefAndUserAC)
import Palmares.TxBuilding.Validators (attestationsValidatorGY)
import Test.Fixtures
  ( attestationProfileDataMaxLength,
    auditAttestationData,
    drepProfileData,
    lineageAttestationData,
    milestoneAttestationData,
    orgProfileData,
  )
import Test.Helpers (assert, failedWithTrace)
import Test.Tasty hiding (after) -- see UnitTests.Projections: `after` here is a snapshot, not tasty's
import TestRuns
  ( adminInteraction,
    deployValidators,
    maliciousDoubleAccept,
    maliciousIssueAttestation,
    profileInteraction,
    protocolInteraction,
    sendDustToValidator,
  )

attestationTests :: (HasCallStack) => TestTree
attestationTests =
  testGroup
    "Attestation Tests"
    [ mkTestFor "Test Case 5.1: an organisation issues an attestation about a DRep" orgIssuesAttestation,
      mkTestFor "Test Case 5.2: the subject accepts it" subjectAcceptsAttestation,
      mkTestFor "Test Case 5.3: full attestation lifecycle (two issued, both accepted)" fullLifecycle,
      mkTestFor "Test Case 5.4: Double-accept attestation fails on-chain (A3)" doubleAcceptFails,
      mkTestFor "Test Case 5.5: a wallet that is not the subject cannot accept" wrongUserCannotAccept,
      mkTestFor "Test Case 5.6: a dust sweep beside a real attestation leaves it untouched" sweepLeavesAttestationAlone,
      mkTestFor "Issue attestation with max-length metadata succeeds" maxLengthMetadata,
      mkTestFor "Issue attestation with other_metadata succeeds" withOtherMetadata,
      mkTestFor "Issue attestation with reserved other_metadata key fails" reservedMetadataKeyFails,
      mkTestFor "Test Case 5.10: an attestation whose subject profile does not exist is refused" missingSubjectRefused,
      mkTestFor "Test Case 5.11: an attestation about another ATTESTATION (lineage) succeeds" lineageAttestation,
      mkTestFor "Test Case 5.11b: a lineage attestation can NEVER be accepted, and that is the feature's limit" lineageCannotBeAccepted,
      mkTestFor "Test Case 5.14: other_metadata past the entry limit FAILS (Mn)" oversizedOtherMetadataFails,
      mkTestFor "Test Case 5.12: a back-dated attestation FAILS (Mq, fix #4)" backDatedAttestationFails,
      mkTestFor "Test Case 5.13: an attestation issued with someone else's user NFT FAILS (Mf)" wrongIssuerNFTFails,
      mkTestFor "a paused protocol refuses a profile update and an acceptance, not only an issuance" pauseStopsEverything
    ]
  where
    -- Test Case 5.1. The assertion is the DATUM, not "the transaction did not throw": an attestation
    -- whose subject or issuer is dropped on the way into the record is a record nobody can resolve,
    -- and nothing downstream would notice until a read.
    orgIssuesAttestation :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    orgIssuesAttestation info@TestInfo {..} = do
      (ctx, issuerAC, subjectAC) <- deployWithTwoProfiles info
      (_txId, attestationAC) <- issue ctx (w1 testWallets) subjectAC issuerAC MilestoneDelivered milestoneAttestationData []
      waitNSlots_ 1

      (datum, _value) <- getAttestationDatumAndValue attestationAC
      let att = extra datum
      assert (OnchainTypes.attestationSubject att == assetClassToPlutus subjectAC)
      assert (OnchainTypes.attestationIssuer att == assetClassToPlutus issuerAC)
      assert (OnchainTypes.attestationKind att == OnchainTypes.MilestoneDelivered)
      -- Unaccepted on arrival. An attestation is a claim until its subject counter-signs it, and a
      -- policy that minted one already accepted would let an issuer write someone else's agreement.
      assert (not (OnchainTypes.attestationIsAccepted att))

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "An attestation was issued and recorded unaccepted."

    -- Test Case 5.2.
    subjectAcceptsAttestation :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    subjectAcceptsAttestation info@TestInfo {..} = do
      (ctx, issuerAC, subjectAC) <- deployWithTwoProfiles info
      (_txId, attestationAC) <- issue ctx (w1 testWallets) subjectAC issuerAC MilestoneDelivered milestoneAttestationData []
      waitNSlots_ 1

      void $ profileInteraction ctx (w2 testWallets) (AcceptAttestationAction attestationAC) Nothing
      waitNSlots_ 1

      (datum, _value) <- getAttestationDatumAndValue attestationAC
      assert (OnchainTypes.attestationIsAccepted (extra datum))
      -- And acceptance changed ONLY that. The validator compares the whole datum, so anything else
      -- that moved would have been rejected on chain — this says the off-chain mirror agrees.
      assert (OnchainTypes.attestationSubject (extra datum) == assetClassToPlutus subjectAC)
      assert (OnchainTypes.attestationIssuer (extra datum) == assetClassToPlutus issuerAC)

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "The subject accepted; only the acceptance flag moved."

    -- Test Case 5.3. Two attestations about one subject, both accepted — the case that would catch a
    -- seed collision or an accept that resolves the wrong UTxO.
    fullLifecycle :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    fullLifecycle info@TestInfo {..} = do
      (ctx, issuerAC, subjectAC) <- deployWithTwoProfiles info
      (_t1, attA) <- issue ctx (w1 testWallets) subjectAC issuerAC MilestoneDelivered milestoneAttestationData []
      waitNSlots_ 1
      (_t2, attB) <- issue ctx (w1 testWallets) subjectAC issuerAC AuditPassed auditAttestationData []
      waitNSlots_ 1
      assert (attA /= attB)

      void $ profileInteraction ctx (w2 testWallets) (AcceptAttestationAction attA) Nothing
      waitNSlots_ 1
      void $ profileInteraction ctx (w2 testWallets) (AcceptAttestationAction attB) Nothing
      waitNSlots_ 1

      (datumA, _) <- getAttestationDatumAndValue attA
      (datumB, _) <- getAttestationDatumAndValue attB
      assert (OnchainTypes.attestationIsAccepted (extra datumA))
      assert (OnchainTypes.attestationIsAccepted (extra datumB))
      assert (OnchainTypes.attestationKind (extra datumA) == OnchainTypes.MilestoneDelivered)
      assert (OnchainTypes.attestationKind (extra datumB) == OnchainTypes.AuditPassed)

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Two attestations issued and both accepted."

    -- Test Case 5.4, and it is a different test from the one it replaces. The inherited version named
    -- trace @TA@, a code that exists nowhere, and asserted nothing but @mustFail@ — which passed
    -- because `acceptAttestationTX` throws @AttestationAlreadyAccepted@ off chain. @A3@ is T-ATTEST-3's
    -- guard and it is the one that holds when somebody builds the transaction themselves: without it
    -- a second accept rewrites an identical datum and succeeds, leaving a permanent record whose
    -- acceptance is whatever the last accepter chose.
    doubleAcceptFails :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    doubleAcceptFails info@TestInfo {..} = do
      (ctx, issuerAC, subjectAC) <- deployWithTwoProfiles info
      (_txId, attestationAC) <- issue ctx (w1 testWallets) subjectAC issuerAC MilestoneDelivered milestoneAttestationData []
      waitNSlots_ 1

      void $ profileInteraction ctx (w2 testWallets) (AcceptAttestationAction attestationAC) Nothing
      waitNSlots_ 1

      mustFailWith (failedWithTrace "A3") $ void $ maliciousDoubleAccept ctx (w2 testWallets) attestationAC

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A second acceptance was rejected by the validator (A3)."

    -- Test Case 5.5. Plain 'mustFail' and no code on purpose: w3 holds no user token for the subject
    -- profile, so `txMustSpendFromAddress` throws @ProfileNotFound@ and no script runs. The on-chain
    -- half of this rule is @A1@'s subject-user-NFT check, which the double-accept case above reaches
    -- the validator to exercise.
    wrongUserCannotAccept :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    wrongUserCannotAccept info@TestInfo {..} = do
      (ctx, issuerAC, subjectAC) <- deployWithTwoProfiles info
      (_txId, attestationAC) <- issue ctx (w1 testWallets) subjectAC issuerAC MilestoneDelivered milestoneAttestationData []
      waitNSlots_ 1

      mustFail $ void $ profileInteraction ctx (w3 testWallets) (AcceptAttestationAction attestationAC) Nothing

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A wallet that is not the subject could not accept."

    -- Test Case 5.6, which the Cleanup module could not write: it needs real protocol state beside
    -- the dust. The off-chain selector keeps the attestation out of the sweep because it carries a
    -- protocol token, and the assertion is datum EQUALITY rather than "the sweep did not crash" —
    -- silent corruption is the thing worth catching here.
    sweepLeavesAttestationAlone :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    sweepLeavesAttestationAlone info@TestInfo {..} = do
      (ctx, issuerAC, subjectAC) <- deployWithTwoProfiles info
      (_txId, attestationAC) <- issue ctx (w1 testWallets) subjectAC issuerAC MilestoneDelivered milestoneAttestationData []
      waitNSlots_ 1
      before <- getAttestationDatumAndValue attestationAC

      sendDustToValidator (w2 testWallets) attestationsValidatorGY
      waitNSlots_ 1
      _txId <- protocolInteraction ctx (w3 testWallets) CleanupDustAction
      waitNSlots_ 1

      after <- getAttestationDatumAndValue attestationAC
      assert (after == before)
      -- And the dust really went, so the sweep was not a no-op that trivially left things alone.
      attestationsAddr <- scriptAddress attestationsValidatorGY
      assert . (== 1) . length . utxosToList =<< utxosAtAddresses [attestationsAddr]

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Dust swept; the attestation beside it is byte-identical."

    maxLengthMetadata :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    maxLengthMetadata info@TestInfo {..} = do
      (ctx, issuerAC, subjectAC) <- deployWithTwoProfiles info
      -- Exactly on the CIP-68 limits: name 128, description 1024, image URI 256. One byte over and
      -- @Mm@ rejects, which is what makes this the boundary rather than a large-ish fixture.
      void $ issue ctx (w1 testWallets) subjectAC issuerAC Endorsement attestationProfileDataMaxLength []
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Max-length metadata accepted at the byte boundary."

    withOtherMetadata :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    withOtherMetadata info@TestInfo {..} = do
      (ctx, issuerAC, subjectAC) <- deployWithTwoProfiles info
      void $
        issue
          ctx
          (w1 testWallets)
          subjectAC
          issuerAC
          MilestoneDelivered
          milestoneAttestationData
          [("fund", "Catalyst Fund 12"), ("project", "1200123")]
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Free-form other_metadata accepted."

    -- Build-time, and that is the only place it can be: @name@/@description@/@image@ are the keys
    -- `mkCIP68Datum` writes itself, so a caller that supplied one would be overwriting a CIP-68
    -- standard field with a value no reader expects there.
    reservedMetadataKeyFails :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    reservedMetadataKeyFails info@TestInfo {..} = do
      (ctx, issuerAC, subjectAC) <- deployWithTwoProfiles info
      mustFail $
        void $
          issue ctx (w1 testWallets) subjectAC issuerAC MilestoneDelivered milestoneAttestationData [("name", "shadow")]
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A reserved other_metadata key was refused before building."

    -- Test Case 5.10, REVIEW FOCUS ITEM 3 — and the plan's wording for it is now out of date, which
    -- is worth stating rather than quietly fixing. It read "an attestation whose subject profile does
    -- not exist MINTS, and is unacceptable forever", because the minting policy checks only that the
    -- subject's asset class carries the protocol currency symbol (@Mg@) and nothing in this protocol
    -- burns: such a record could never be counter-signed and never removed. T-ATTEST-6 closed that
    -- off chain with `ensureSubjectProfileExists`, so the permanent-pending record is no longer
    -- reachable through the API and the honest assertion is the refusal.
    --
    -- It is still only an off-chain guard. A client building its own transaction can still mint one,
    -- which is why the error exists as its own 404 rather than folding into the issuer's.
    missingSubjectRefused :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    missingSubjectRefused info@TestInfo {..} = do
      (ctx, issuerAC, _subjectAC) <- deployWithTwoProfiles info
      -- A well-formed protocol asset class that was never minted: derived from a seed UTxO nobody
      -- spent, so it carries the right currency symbol and @Mg@ would be satisfied.
      ghostAC <- do
        seed <- someUTxOWithoutRefScript
        fst <$> gyGenerateRefAndUserAC (getMintingPolicyFromCtx ctx) seed

      mustFail $
        void $
          issue ctx (w1 testWallets) ghostAC issuerAC Endorsement milestoneAttestationData []

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "An attestation about a non-existent subject was refused (SubjectProfileNotFound)."

    -- Test Case 5.11. `ensureSubjectProfileExists` checks EXISTENCE and deliberately not kind, so an
    -- attestation about an earlier attestation is permitted: that is the lineage record the spec asks
    -- for — a second issuer endorsing a claim rather than its subject. The subject here is an
    -- attestation id, and the acceptance path for it is intentionally dead, since an attestation has
    -- no user token and nobody can counter-sign on its behalf.
    lineageAttestation :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    lineageAttestation info@TestInfo {..} = do
      (ctx, issuerAC, subjectAC) <- deployWithTwoProfiles info
      (_t1, baseAC) <- issue ctx (w1 testWallets) subjectAC issuerAC MilestoneDelivered milestoneAttestationData []
      waitNSlots_ 1

      (_t2, lineageAC) <- issue ctx (w1 testWallets) baseAC issuerAC Endorsement lineageAttestationData []
      waitNSlots_ 1

      (datum, _value) <- getAttestationDatumAndValue lineageAC
      assert (OnchainTypes.attestationSubject (extra datum) == assetClassToPlutus baseAC)
      assert (lineageAC /= baseAC)

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "An attestation about an attestation landed."

    -- Test Case 5.11b. THE LIMIT OF THE FEATURE ABOVE, which nothing stated until an audit looked.
    --
    -- `A1` requires the transaction to spend the user NFT derived from the subject's id, and that is
    -- how a subject consents. An attestation mints only a reference token — no user token exists to
    -- spend — so a lineage attestation cannot be accepted by anybody, ever. It stays
    -- `isAccepted = False` for as long as the chain exists, and nothing burns it.
    --
    -- This is asserted rather than fixed, and the reasoning is written down here because the
    -- alternative is worse than the limit. Accepting a lineage record would mean letting the SUBJECT
    -- ATTESTATION's own subject consent on its behalf, which needs that attestation as a reference
    -- input on the accept path — and the validator cannot tell a profile id from an attestation id,
    -- since both are CIP-67 reference tokens of the same policy. So it would cost a reference input
    -- on EVERY acceptance to serve a case that has no user yet.
    --
    -- What the limit actually requires is a READ-LAYER distinction: an `Endorsement` of a record is
    -- its issuer's statement and stands on the issuer alone, so presenting it as "pending" — which
    -- is what `isAccepted = False` reads as on a normal attestation — is the real defect. That is
    -- T-ATTEST-9's business, not a validator's.
    --
    -- `mustFail` and not `mustFailWith`: the off-chain path refuses first, because
    -- `acceptAttestationTX` looks for the subject's user NFT and there is none to find. A trace-code
    -- assertion here would be asserting which layer happens to say no first.
    lineageCannotBeAccepted :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    lineageCannotBeAccepted info@TestInfo {..} = do
      (ctx, issuerAC, subjectAC) <- deployWithTwoProfiles info
      (_t1, baseAC) <- issue ctx (w1 testWallets) subjectAC issuerAC MilestoneDelivered milestoneAttestationData []
      waitNSlots_ 1
      (_t2, lineageAC) <- issue ctx (w1 testWallets) baseAC issuerAC Endorsement lineageAttestationData []
      waitNSlots_ 1

      -- w2 holds the base attestation's SUBJECT profile, which is the closest thing to an interested
      -- party. It is not enough, and that is the point.
      mustFail $ void $ profileInteraction ctx (w2 testWallets) (AcceptAttestationAction lineageAC) Nothing
      -- w1 issued both, which is not enough either: an issuer accepting its own claim is the thing
      -- `A1` exists to prevent.
      mustFail $ void $ profileInteraction ctx (w1 testWallets) (AcceptAttestationAction lineageAC) Nothing

      (datum, _value) <- getAttestationDatumAndValue lineageAC
      assert (not (OnchainTypes.attestationIsAccepted (extra datum)))

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A lineage attestation stayed unaccepted, as it always will."

    -- Test Case 5.14. `Mn`. `otherMetadata` went into the permanent datum unbounded, and the cost
    -- lands on the SUBJECT rather than the issuer who paid for it: `A1` re-locks `ownValue`, so the
    -- subject is who has to spend and relock that UTxO to accept, and nothing can remove it.
    --
    -- Reachable through the production path, which is what made it a finding: the off-chain guard
    -- checks reserved-key collisions only, not the count, not the sizes, and not duplicates among
    -- the caller's own keys.
    oversizedOtherMetadataFails :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    oversizedOtherMetadataFails info@TestInfo {..} = do
      (ctx, issuerAC, subjectAC) <- deployWithTwoProfiles info
      let tooMany = [(T.pack ("k" <> show i), "v") | i <- [1 .. 17 :: Int]]
      mustFailWith (failedWithTrace "Mn") $
        void $
          issue ctx (w1 testWallets) subjectAC issuerAC MilestoneDelivered milestoneAttestationData tooMany
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "An oversized other_metadata map was rejected (Mn)."

    -- Test Case 5.12, inherited fix #4 end to end. @Ml@ requires the recorded date to fall inside the
    -- transaction's validity interval, and the interval is built from the chain tip — so a date ten
    -- minutes in the past is outside it. The production path cannot produce this at all any more: the
    -- date is derived from `slotOfCurrentBlock` and is not a request field, which is the off-chain
    -- half of the same fix. Without @Ml@, an issuer could stamp any date they liked on a record the
    -- chain then presents as fact.
    backDatedAttestationFails :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    backDatedAttestationFails info@TestInfo {..} = do
      (ctx, issuerAC, subjectAC) <- deployWithTwoProfiles info
      mustFailWith (failedWithTrace "Mq") $
        void $
          maliciousIssueAttestation
            ctx
            (w1 testWallets)
            subjectAC
            issuerAC
            MilestoneDelivered
            (profileDataToMetadataFields milestoneAttestationData)
            600_000 -- ten minutes before the tip
            issuerAC
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A back-dated attestation was rejected (Mq)."

    -- Test Case 5.13. @Mf@ is the only thing standing between this protocol and anyone issuing
    -- attestations as anyone else: authority here is token possession, so the transaction has to
    -- SPEND the named issuer's user token. Here w2 names w1's organisation as the issuer and pays
    -- with its own profile's token instead — the exact impersonation the check exists for.
    --
    -- Unreachable through the API, which looks the issuer's token up in the caller's own addresses
    -- and returns @ProfileNotFound@ long before any script runs.
    wrongIssuerNFTFails :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    wrongIssuerNFTFails info@TestInfo {..} = do
      (ctx, issuerAC, subjectAC) <- deployWithTwoProfiles info
      mustFailWith (failedWithTrace "Mf") $
        void $
          maliciousIssueAttestation
            ctx
            (w2 testWallets)
            subjectAC
            issuerAC -- named in the redeemer and the datum
            Endorsement
            (profileDataToMetadataFields milestoneAttestationData)
            0
            subjectAC -- but w2's own profile's token is what pays
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "An attestation paid for with the wrong user NFT was rejected (Mf)."

    -- The pause is the only lever there is when something is going wrong on chain, and until
    -- T-ATTEST-6 it moved almost nothing: only `issueAttestationTX` read the oracle, so a paused
    -- protocol still accepted profile updates and acceptances. All three paths now attach the oracle
    -- reference input and `getOracleRefInputSkeleton` refuses on @opPaused@.
    --
    -- __Plain 'mustFail', NOT 'failedWithTrace'.__ @ProtocolPaused@ is raised at skeleton-BUILD time
    -- by the off-chain builder, so no script runs and there is no trace code to match. A
    -- `failedWithTrace` assertion here would never match, the test would report a pass, and it would
    -- have asserted nothing at all.
    pauseStopsEverything :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    pauseStopsEverything info@TestInfo {..} = do
      (ctx, issuerAC, subjectAC) <- deployWithTwoProfiles info
      (_txId, attestationAC) <- issue ctx (w1 testWallets) subjectAC issuerAC MilestoneDelivered milestoneAttestationData []
      waitNSlots_ 1

      _ <- adminInteraction ctx (w1 testWallets) PauseProtocolAction
      waitNSlots_ 1

      mustFail $
        void $
          profileInteraction
            ctx
            (w1 testWallets)
            (UpdateProfileAction issuerAC (Just "a new description") "ipfs://QmUpdated")
            Nothing
      mustFail $ void $ profileInteraction ctx (w2 testWallets) (AcceptAttestationAction attestationAC) Nothing
      mustFail $
        void $
          issue ctx (w1 testWallets) subjectAC issuerAC AuditPassed auditAttestationData []

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A paused protocol refused an update, an acceptance and an issuance."

    -- Deploy, then give w1 an organisation and w2 a DRep person. Every case below needs both, and an
    -- issuer and a subject held by DIFFERENT wallets is what makes the acceptance path meaningful.
    deployWithTwoProfiles ::
      (HasCallStack) => TestInfo -> GYTxMonadClb (DeployedScriptsContext, GYAssetClass, GYAssetClass)
    deployWithTwoProfiles TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000
      (_t1, issuerAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          (ClaimProfileAction Organization orgProfileData)
          Nothing
      waitNSlots_ 1
      (_t2, subjectAC) <-
        profileInteraction
          ctx
          (w2 testWallets)
          (ClaimProfileAction PersonDRep drepProfileData)
          Nothing
      waitNSlots_ 1
      return (ctx, issuerAC, subjectAC)

    issue ::
      (HasCallStack) =>
      DeployedScriptsContext ->
      User ->
      GYAssetClass ->
      GYAssetClass ->
      AttestationType ->
      ProfileData ->
      [(Text, Text)] ->
      GYTxMonadClb (GYTxId, GYAssetClass)
    issue ctx issuerWallet subjectAC issuerAC kind pdata otherMeta =
      profileInteraction
        ctx
        issuerWallet
        ( IssueAttestationAction
            { aa_subject_profile_id = subjectAC,
              aa_issuer_profile_id = issuerAC,
              aa_kind = kind,
              aa_profile_data = pdata,
              aa_other_metadata = otherMeta,
              -- The self-reported period is exercised by 'UnitTests.WritePath' and
              -- 'PropertyTests'; left out here so these cases pin the issuance path and not it.
              aa_claimed_period = Nothing
            }
        )
        Nothing
