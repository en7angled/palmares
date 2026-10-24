{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The attestation read surface: "Query.Attest" against a real @palmares_attest@ schema.
--
-- __Why the reads do NOT go through @runAttest@.__ The fixtures are written through it, because
-- that is how @attest-sync@ writes them, but every read below goes through 'runPg' — a plain
-- transaction on the default @search_path@, which is what 'QueryAppMonad.runRead' gives a handler:
-- 'Query.Gov.runGovRead' pins a statement timeout and nothing else. @palmares_attest@ is not on
-- that path, so an unqualified @FROM profile_projection@ in "Query.Attest" would fail here with
-- @relation \"profile_projection\" does not exist@ on every single case. That is the point: the
-- schema-qualified @FROM@ clauses are load-bearing and this module is what holds them.
--
-- __The credential cases are the ones to read first.__ @\/profiles\/by-credential@ is the endpoint
-- the word \"verified\" rests on, and the failure it exists to prevent is silent: accepting a
-- CIP-105 id or a bare hex hash means choosing a header byte, and choosing the key byte reports
-- every script DRep as a key DRep. So there are cases for a key credential, for a script
-- credential over THE SAME 28 bytes, for each refused form, and for one credential claimed twice.
module UnitTests.AttestRead (attestReadTests) where

import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Database.Persist (insert_)
import Database.Persist.Sql (ConnectionPool)
import GeniusYield.Types (GYAssetClass, GYTime, timeFromPOSIX)
import Palmares.ChainSync.KupoAtlas (toGYAssetClass)
import Palmares.DomainTypes.Core.Ids (drepIdCip105, drepIdCip129)
import Palmares.DomainTypes.Core.Types
  ( AttestationOtherMetadataJson (..),
    AttestationType (..),
    DisputeVerdict (..),
    ProfileType (..),
  )
import Palmares.DomainTypes.Transfer.Filters
  ( AttestProfileFilter (..),
    AttestationRecordFilter (..),
    DisputeFilter (..),
    emptyAttestProfileFilter,
    emptyAttestationRecordFilter,
    emptyDisputeFilter,
  )
import Palmares.DomainTypes.Transfer.OrderBy (AttestationsOrderBy (..), ProfilesOrderBy (..), SortOrder (..))
import Palmares.DomainTypes.Transfer.QueryResponses
  ( AttestProfileRow (..),
    AttestationDetailResponse (..),
    AttestationRow (..),
    DisputeRow (..),
  )
import Palmares.Storage
  ( AttestationProjection (..),
    DisputeProjection (..),
    ProfileProjection (..),
    ensureAttestSchema,
    runAttest,
    runMigrations,
  )
import Palmares.WebAPI.Envelope (Page (..))
import Query.Attest
  ( attestationById,
    attestationSortSpec,
    canonicalGovCredential,
    credentialIsScript,
    listAttestations,
    listDisputes,
    listProfiles,
    profileById,
    subjectTrackRecordSortSpec,
  )
import Query.Common (jsonBounds, normalizeLimitOffset)
import Test.Pg (runPg, withScratchDb)
import Test.Tasty
import Test.Tasty.HUnit

------------------------------------------------------------------------------------------------

-- * Fixtures

------------------------------------------------------------------------------------------------

-- | A real asset class or a loud failure. 56 hex characters of policy, then a token name in hex —
-- a short policy is rejected by 'toGYAssetClass' rather than stored as something that will not
-- compare equal later.
ac :: Text -> GYAssetClass
ac t = either (error . ("bad asset-class fixture: " <>)) id (toGYAssetClass t)

acAlice, acBob, acOrg, acScriptClaimant, acUnclaimed :: GYAssetClass
acAlice = ac "c0ffee00000000000000000000000000000000000000000000000001.000643b0a1"
acBob = ac "c0ffee00000000000000000000000000000000000000000000000001.000643b0b2"
acOrg = ac "c0ffee00000000000000000000000000000000000000000000000001.000643b0c3"
acScriptClaimant = ac "c0ffee00000000000000000000000000000000000000000000000001.000643b0c4"
acUnclaimed = ac "c0ffee00000000000000000000000000000000000000000000000001.000643b0c5"

-- | A profile id that is well-formed and never inserted: the 404 fixture.
acMissing :: GYAssetClass
acMissing = ac "c0ffee00000000000000000000000000000000000000000000000001.000643b0ff"

acAtt1, acAtt2, acAtt3, acAttMissing :: GYAssetClass
acAtt1 = ac "c0ffee00000000000000000000000000000000000000000000000001.000643b0d1"
acAtt2 = ac "c0ffee00000000000000000000000000000000000000000000000001.000643b0d2"
acAtt3 = ac "c0ffee00000000000000000000000000000000000000000000000001.000643b0d3"
acAttMissing = ac "c0ffee00000000000000000000000000000000000000000000000001.000643b0de"

acDispute1, acDispute2 :: GYAssetClass
acDispute1 = ac "c0ffee00000000000000000000000000000000000000000000000001.000643b0e1"
acDispute2 = ac "c0ffee00000000000000000000000000000000000000000000000001.000643b0e2"

-- | The \"Bitcows\" preprod DRep credential hash, the same 28 bytes @UnitTests.GovIds@ pins its
-- golden vectors against. Reused on purpose: the key and the script renderings below are the same
-- hash, which is the collision a lenient codec would resolve by guessing.
credentialRaw :: ByteString
credentialRaw = B16.decodeLenient "81378d3ea89b68f0fc09944b1f93f2feb851318f196f98ba4029d8a8"

-- | A second, unrelated credential, so \"found the right one\" is distinguishable from \"found
-- the only one\".
otherRaw :: ByteString
otherRaw = B16.decodeLenient "0123456789abcdef0123456789abcdef0123456789abcdef01234567"

keyCredential, scriptCredential, cip105Credential, hexCredential :: Text
keyCredential = drepIdCip129 False credentialRaw
scriptCredential = drepIdCip129 True credentialRaw
cip105Credential = drepIdCip105 credentialRaw
hexCredential = "81378d3ea89b68f0fc09944b1f93f2feb851318f196f98ba4029d8a8"

-- | A 32-byte transaction id, as 64 hex characters. Short ids are what make a Cardano fixture fail
-- deep inside with a confusing message, so they are spelled in full here.
txIdHex :: Text
txIdHex = "aa00000000000000000000000000000000000000000000000000000000000001"

at :: Integer -> GYTime
at = timeFromPOSIX . fromIntegral

profileFx :: Integer -> GYAssetClass -> Text -> ProfileType -> Maybe Text -> ProfileProjection
profileFx slot pid name kind credential =
  ProfileProjection
    { profileProjectionCreatedAtSlot = slot,
      profileProjectionCreatedAtHash = "hdr",
      profileProjectionProfileId = pid,
      profileProjectionProfileName = name,
      profileProjectionProfileDescription = name <> " of Palmares",
      profileProjectionProfileImageURI = "ipfs://QmFixture",
      profileProjectionProfileType = kind,
      profileProjectionProfileCredential = credential
    }

attestationFx ::
  Integer ->
  GYAssetClass ->
  GYAssetClass ->
  GYAssetClass ->
  AttestationType ->
  Integer ->
  Bool ->
  AttestationProjection
attestationFx slot aid subject issuer kind date accepted =
  AttestationProjection
    { attestationProjectionCreatedAtSlot = slot,
      attestationProjectionCreatedAtHash = "hdr",
      attestationProjectionCreatedTxId = txIdHex,
      attestationProjectionCreatedOutputIndex = 0,
      attestationProjectionAttestationId = aid,
      attestationProjectionSubjectProfileId = subject,
      attestationProjectionIssuerProfileId = issuer,
      attestationProjectionAttestationKind = kind,
      attestationProjectionAttestationCredential = Nothing,
      attestationProjectionAttestationDate = at date,
      attestationProjectionClaimedPeriodFrom = Just (at (date - 1000)),
      attestationProjectionClaimedPeriodTo = Just (at date),
      attestationProjectionIsAccepted = accepted,
      attestationProjectionAttestationName = "att-" <> txIdHex,
      attestationProjectionAttestationDescription = "a description",
      attestationProjectionAttestationImageURI = "ipfs://QmAtt",
      attestationProjectionOtherMetadata = Just (AttestationOtherMetadataJson [("role", "auditor")])
    }

disputeFx :: Integer -> GYAssetClass -> GYAssetClass -> Maybe DisputeVerdict -> DisputeProjection
disputeFx slot did target verdict =
  DisputeProjection
    { disputeProjectionCreatedAtSlot = slot,
      disputeProjectionCreatedAtHash = "hdr",
      disputeProjectionDisputeId = did,
      disputeProjectionTargetAttestationId = target,
      disputeProjectionOpenedByProfileId = acBob,
      disputeProjectionOpenedAt = at slot,
      disputeProjectionDeposit = 5_000_000,
      disputeProjectionVerdict = verdict,
      disputeProjectionDisputeName = "a dispute",
      disputeProjectionDisputeDescription = "a disputed claim",
      disputeProjectionDisputeImageURI = "ipfs://QmDis"
    }

-- | Five profiles, three attestations, two disputes.
--
--   * @acAlice@ claims the credential as a KEY credential;
--   * @acScriptClaimant@ claims the SAME 28 bytes as a SCRIPT credential;
--   * @acBob@ claims the same KEY credential as Alice, later — the contested case;
--   * @acOrg@ claims a different credential;
--   * @acUnclaimed@ claims none.
seedAll :: ConnectionPool -> IO ()
seedAll pool = runAttest pool $ do
  insert_ (profileFx 100 acAlice "Alice" PersonDRep (Just keyCredential))
  insert_ (profileFx 200 acScriptClaimant "AliceScript" PersonDRep (Just scriptCredential))
  insert_ (profileFx 300 acBob "Bob" PersonDRep (Just keyCredential))
  insert_ (profileFx 400 acOrg "Orgsson" Organization (Just (drepIdCip129 False otherRaw)))
  insert_ (profileFx 500 acUnclaimed "Nobody" Vendor Nothing)
  -- Two about Alice: an unaccepted NEWER one and an accepted OLDER one, so "accepted first" and
  -- "newest first" disagree and the track-record ordering is not vacuous.
  insert_ (attestationFx 600 acAtt1 acAlice acOrg AuditPassed 1_700_000_000 True)
  insert_ (attestationFx 700 acAtt2 acAlice acOrg Endorsement 1_800_000_000 False)
  -- One about Bob, so a subject filter can be wrong by returning everything.
  insert_ (attestationFx 800 acAtt3 acBob acAlice Affiliation 1_900_000_000 True)
  insert_ (disputeFx 900 acDispute1 acAtt1 Nothing)
  insert_ (disputeFx 1000 acDispute2 acAtt1 (Just VerdictRejected))

-- | A scratch database with the attestation schema migrated and the fixtures in it.
seeded :: (ConnectionPool -> IO a) -> IO a
seeded body = withScratchDb $ \pool -> do
  runPg pool ensureAttestSchema
  runAttest pool runMigrations
  seedAll pool
  body pool

-- | The default page: the whole fixture set fits in it.
page1 :: (Int, Int)
page1 = (50, 0)

------------------------------------------------------------------------------------------------

-- * Cases

------------------------------------------------------------------------------------------------

attestReadTests :: TestTree
attestReadTests =
  testGroup
    "attestation read surface"
    [ testGroup "the credential codec is strict" codecTests,
      testGroup "GET /profiles" profileListTests,
      testGroup "GET /profiles/{id}" profileDetailTests,
      testGroup "GET /profiles/by-credential/{credential}" byCredentialTests,
      testGroup "GET /profiles/{id}/attestations" trackRecordTests,
      testGroup "GET /attestations" attestationListTests,
      testGroup "GET /attestations/{id}" attestationDetailTests,
      testGroup "GET /disputes" disputeTests,
      testGroup "pagination boundaries" paginationTests
    ]

-- | Pure, and the most important group here: these four refusals are the whole difference between
-- a verification endpoint and a guess.
codecTests :: [TestTree]
codecTests =
  [ testCase "a CIP-129 key credential canonicalises to itself" $
      canonicalGovCredential keyCredential @?= Just keyCredential,
    testCase "a CIP-129 script credential canonicalises to itself, NOT to the key form" $
      canonicalGovCredential scriptCredential @?= Just scriptCredential,
    -- The two renderings are the same 28 bytes, so a codec that dropped the header byte would
    -- make these equal and every assertion below vacuous.
    testCase "the key and script renderings of one hash are different identifiers" $
      assertBool "key and script forms collided" (keyCredential /= scriptCredential),
    testCase "a CIP-105 id is REFUSED: it carries no header byte" $
      canonicalGovCredential cip105Credential @?= Nothing,
    testCase "56 bare hex characters are REFUSED for the same reason" $
      canonicalGovCredential hexCredential @?= Nothing,
    testCase "garbage is refused" $ do
      canonicalGovCredential "" @?= Nothing
      canonicalGovCredential "drep_always_abstain" @?= Nothing
      canonicalGovCredential "pool1xyz" @?= Nothing,
    -- All-upper-case is a VALID bech32 spelling of the same id (BIP-173 forbids only mixed case),
    -- and going through the parse and back out is what makes it match a stored lower-case one.
    testCase "an upper-case bech32 spelling canonicalises to the stored lower-case form" $
      canonicalGovCredential (T.toUpper keyCredential) @?= Just keyCredential,
    testCase "credentialIsScript reads the header byte and never guesses" $ do
      credentialIsScript keyCredential @?= Just False
      credentialIsScript scriptCredential @?= Just True
      credentialIsScript cip105Credential @?= Nothing
      credentialIsScript "not a credential" @?= Nothing
  ]

profileListTests :: [TestTree]
profileListTests =
  [ testCase "the unfiltered page carries every profile and a total" $
      seeded $ \pool -> do
        p <- runPg pool (listProfiles emptyAttestProfileFilter (ProfilesOrderByRegisteredAt, Asc) page1)
        (map attestProfileName (pageItems p), pageTotal p)
          @?= (["Alice", "AliceScript", "Bob", "Orgsson", "Nobody"], Just 5),
    testCase "kind is repeatable and an EMPTY list is no filter, not 'match nothing'" $
      seeded $ \pool -> do
        vendors <- names pool emptyAttestProfileFilter {attestProfileFilterKinds = [Vendor]}
        both <-
          names pool emptyAttestProfileFilter {attestProfileFilterKinds = [Vendor, Organization]}
        none <- names pool emptyAttestProfileFilter {attestProfileFilterKinds = []}
        (vendors, both, length none) @?= (["Nobody"], ["Orgsson", "Nobody"], 5),
    testCase "claimed=true keeps only the profiles that claim a credential" $
      seeded $ \pool -> do
        ns <- names pool emptyAttestProfileFilter {attestProfileFilterClaimed = Just True}
        ns @?= ["Alice", "AliceScript", "Bob", "Orgsson"],
    testCase "claimed=false keeps only the profiles that claim none" $
      seeded $ \pool -> do
        ns <- names pool emptyAttestProfileFilter {attestProfileFilterClaimed = Just False}
        ns @?= ["Nobody"],
    testCase "q matches name and description, case-insensitively" $
      seeded $ \pool -> do
        byName <- names pool emptyAttestProfileFilter {attestProfileFilterQ = Just "ALIC"}
        byDescription <- names pool emptyAttestProfileFilter {attestProfileFilterQ = Just "of palmares"}
        (byName, length byDescription) @?= (["Alice", "AliceScript"], 5),
    -- A % the user typed is a character they are searching for, not a wildcard they are setting.
    testCase "a % in q is matched literally rather than as a wildcard" $
      seeded $ \pool -> do
        ns <- names pool emptyAttestProfileFilter {attestProfileFilterQ = Just "%"}
        ns @?= [],
    testCase "order_by name is case-insensitive, and sort_order reverses it" $
      seeded $ \pool -> do
        asc <- runPg pool (listProfiles emptyAttestProfileFilter (ProfilesOrderByName, Asc) page1)
        desc <- runPg pool (listProfiles emptyAttestProfileFilter (ProfilesOrderByName, Desc) page1)
        ( map attestProfileName (pageItems asc),
          map attestProfileName (pageItems desc)
          )
          @?= ( ["Alice", "AliceScript", "Bob", "Nobody", "Orgsson"],
                ["Orgsson", "Nobody", "Bob", "AliceScript", "Alice"]
              ),
    testCase "credential_is_script is decoded from the stored identifier, per row" $
      seeded $ \pool -> do
        p <- runPg pool (listProfiles emptyAttestProfileFilter (ProfilesOrderByRegisteredAt, Asc) page1)
        map (\r -> (attestProfileName r, attestProfileCredentialIsScript r)) (pageItems p)
          @?= [ ("Alice", Just False),
                ("AliceScript", Just True),
                ("Bob", Just False),
                ("Orgsson", Just False),
                ("Nobody", Nothing)
              ]
  ]
  where
    names pool f = do
      p <- runPg pool (listProfiles f (ProfilesOrderByRegisteredAt, Asc) page1)
      pure (map attestProfileName (pageItems p))

profileDetailTests :: [TestTree]
profileDetailTests =
  [ testCase "a profile that exists comes back whole, with its slot and block hash" $
      seeded $ \pool -> do
        r <- runPg pool (profileById acAlice)
        fmap (\p -> (attestProfileName p, attestProfileSlot p, attestProfileCredential p)) r
          @?= Just ("Alice", 100, Just keyCredential),
    -- Nothing is what the handler turns into 404 profile_not_found.
    testCase "a well-formed id that names nothing is Nothing, which is the 404" $
      seeded $ \pool -> do
        r <- runPg pool (profileById acMissing)
        fmap attestProfileName r @?= Nothing
  ]

byCredentialTests :: [TestTree]
byCredentialTests =
  [ testCase "a KEY DRep credential finds its claimants, oldest claim first" $
      seeded $ \pool -> do
        p <- byCredential pool keyCredential
        (map attestProfileName (pageItems p), pageTotal p) @?= (["Alice", "Bob"], Just 2),
    -- The one that a lenient codec breaks: the same 28 bytes, claimed as a script credential.
    testCase "a SCRIPT DRep credential finds the script claimant and NOT the key ones" $
      seeded $ \pool -> do
        p <- byCredential pool scriptCredential
        (map attestProfileName (pageItems p), pageTotal p) @?= (["AliceScript"], Just 1),
    testCase "total > 1 is the contested signal, and the API picks no winner" $
      seeded $ \pool -> do
        contested <- byCredential pool keyCredential
        single <- byCredential pool scriptCredential
        (pageTotal contested, pageTotal single) @?= (Just 2, Just 1),
    testCase "a credential nobody claims is an empty page, not an error" $
      seeded $ \pool -> do
        p <- byCredential pool (drepIdCip129 True otherRaw)
        (pageItems p, pageTotal p) @?= ([], Just 0),
    -- The handler canonicalises before querying, so the route and this case go through the same
    -- step: an upper-case paste finds the same rows as the lower-case one.
    testCase "an upper-case spelling of a claimed credential still finds it" $
      seeded $ \pool -> do
        c <-
          maybe (assertFailure "the canonicaliser refused a valid upper-case id") pure $
            canonicalGovCredential (T.toUpper keyCredential)
        p <- byCredential pool c
        map attestProfileName (pageItems p) @?= ["Alice", "Bob"]
  ]
  where
    byCredential pool c =
      runPg
        pool
        ( listProfiles
            emptyAttestProfileFilter {attestProfileFilterCredential = Just c}
            (ProfilesOrderByRegisteredAt, Asc)
            page1
        )

trackRecordTests :: [TestTree]
trackRecordTests =
  [ -- acAtt1 is accepted and OLDER; acAtt2 is unaccepted and NEWER. Newest-first alone would put
    -- acAtt2 at the top, so this ordering is not the one a default would give for free.
    testCase "accepted comes first, then newest within each group" $
      seeded $ \pool -> do
        p <- trackRecord pool acAlice Desc
        map (\r -> (attestationRowId r, attestationRowAccepted r)) (pageItems p)
          @?= [(acAtt1, True), (acAtt2, False)],
    testCase "sort_order asc flips the accepted grouping and keeps dates newest-first" $
      seeded $ \pool -> do
        p <- trackRecord pool acAlice Asc
        map attestationRowId (pageItems p) @?= [acAtt2, acAtt1],
    testCase "the track record is the SUBJECT's, not the issuer's" $
      seeded $ \pool -> do
        -- Alice ISSUED acAtt3 about Bob; it must not appear in Alice's own track record.
        p <- trackRecord pool acAlice Desc
        assertBool "an issued attestation leaked into the subject's record" (acAtt3 `notElem` map attestationRowId (pageItems p)),
    testCase "a profile with no attestations is an empty page with total 0" $
      seeded $ \pool -> do
        p <- trackRecord pool acUnclaimed Desc
        (pageItems p, pageTotal p) @?= ([], Just 0)
  ]
  where
    trackRecord pool pid so =
      runPg
        pool
        ( listAttestations
            emptyAttestationRecordFilter {attestationRecordFilterSubject = Just pid}
            (subjectTrackRecordSortSpec, so)
            page1
        )

attestationListTests :: [TestTree]
attestationListTests =
  [ testCase "the unfiltered page carries every attestation, newest first" $
      seeded $ \pool -> do
        p <- listed pool emptyAttestationRecordFilter
        (map attestationRowId (pageItems p), pageTotal p) @?= ([acAtt3, acAtt2, acAtt1], Just 3),
    testCase "subject and issuer are the two directions and do not collapse" $
      seeded $ \pool -> do
        bySubject <- ids pool emptyAttestationRecordFilter {attestationRecordFilterSubject = Just acAlice}
        byIssuer <- ids pool emptyAttestationRecordFilter {attestationRecordFilterIssuer = Just acAlice}
        (bySubject, byIssuer) @?= ([acAtt2, acAtt1], [acAtt3]),
    testCase "kind is repeatable, and an empty list is no filter" $
      seeded $ \pool -> do
        one' <- ids pool emptyAttestationRecordFilter {attestationRecordFilterKinds = [AuditPassed]}
        two <-
          ids
            pool
            emptyAttestationRecordFilter {attestationRecordFilterKinds = [AuditPassed, Affiliation]}
        none <- ids pool emptyAttestationRecordFilter {attestationRecordFilterKinds = []}
        (one', two, length none) @?= ([acAtt1], [acAtt3, acAtt1], 3),
    testCase "accepted filters both ways and the two partitions sum to the whole" $
      seeded $ \pool -> do
        yes <- ids pool emptyAttestationRecordFilter {attestationRecordFilterAccepted = Just True}
        no <- ids pool emptyAttestationRecordFilter {attestationRecordFilterAccepted = Just False}
        (yes, no) @?= ([acAtt3, acAtt1], [acAtt2]),
    testCase "date_from and date_to bound the issuance date, inclusively" $
      seeded $ \pool -> do
        from <-
          ids pool emptyAttestationRecordFilter {attestationRecordFilterDateFrom = Just (utc 1_800_000_000)}
        to <- ids pool emptyAttestationRecordFilter {attestationRecordFilterDateTo = Just (utc 1_800_000_000)}
        window <-
          ids
            pool
            emptyAttestationRecordFilter
              { attestationRecordFilterDateFrom = Just (utc 1_800_000_000),
                attestationRecordFilterDateTo = Just (utc 1_800_000_000)
              }
        (from, to, window) @?= ([acAtt3, acAtt2], [acAtt2, acAtt1], [acAtt2]),
    testCase "order_by date and sort_order decide the page, with a stable tiebreaker" $
      seeded $ \pool -> do
        asc <-
          runPg
            pool
            ( listAttestations
                emptyAttestationRecordFilter
                (attestationSortSpec AttestationsOrderByDate, Asc)
                page1
            )
        map attestationRowId (pageItems asc) @?= [acAtt1, acAtt2, acAtt3],
    testCase "a row round-trips its claimed period, metadata and chain pointer" $
      seeded $ \pool -> do
        p <- listed pool emptyAttestationRecordFilter {attestationRecordFilterSubject = Just acBob}
        case pageItems p of
          [r] ->
            ( attestationRowClaimedPeriod r,
              attestationRowOtherMetadata r,
              attestationRowTxHash r,
              attestationRowOutputIndex r,
              attestationRowSlot r
            )
              @?= ( Just (at (1_900_000_000 - 1000), at 1_900_000_000),
                    [("role", "auditor")],
                    txIdHex,
                    0,
                    800
                  )
          other -> assertFailure ("expected one attestation about Bob, got " <> show (length other))
  ]
  where
    utc :: Integer -> UTCTime
    utc = posixSecondsToUTCTime . fromIntegral
    listed pool f = runPg pool (listAttestations f (attestationSortSpec AttestationsOrderByDate, Desc) page1)
    ids pool f = map attestationRowId . pageItems <$> listed pool f

attestationDetailTests :: [TestTree]
attestationDetailTests =
  [ testCase "an attestation comes back with its disputes inlined, newest first" $
      seeded $ \pool -> do
        r <- runPg pool (attestationById acAtt1)
        fmap
          ( \d ->
              ( attestationRowId (attestationDetailAttestation d),
                map disputeRowId (attestationDetailDisputes d),
                map disputeRowVerdict (attestationDetailDisputes d)
              )
          )
          r
          @?= Just (acAtt1, [acDispute2, acDispute1], [Just VerdictRejected, Nothing]),
    testCase "an undisputed attestation carries an empty disputes list, not a missing key" $
      seeded $ \pool -> do
        r <- runPg pool (attestationById acAtt2)
        fmap (map disputeRowId . attestationDetailDisputes) r @?= Just [],
    testCase "a well-formed id that names nothing is Nothing, which is the 404" $
      seeded $ \pool -> do
        r <- runPg pool (attestationById acAttMissing)
        fmap (attestationRowId . attestationDetailAttestation) r @?= Nothing
  ]

disputeTests :: [TestTree]
disputeTests =
  [ testCase "the unfiltered page carries every dispute, newest first, with a total" $
      seeded $ \pool -> do
        p <- runPg pool (listDisputes emptyDisputeFilter Desc page1)
        (map disputeRowId (pageItems p), pageTotal p) @?= ([acDispute2, acDispute1], Just 2),
    testCase "target narrows to one attestation's disputes" $
      seeded $ \pool -> do
        mine <- listed pool emptyDisputeFilter {disputeFilterTarget = Just acAtt1}
        other <- listed pool emptyDisputeFilter {disputeFilterTarget = Just acAtt2}
        (mine, other) @?= ([acDispute2, acDispute1], []),
    -- `resolved` is verdict IS NOT NULL, not a verdict value: the column is null while open.
    testCase "resolved=true is the decided ones and resolved=false the open ones" $
      seeded $ \pool -> do
        decided <- listed pool emptyDisputeFilter {disputeFilterResolved = Just True}
        open <- listed pool emptyDisputeFilter {disputeFilterResolved = Just False}
        (decided, open) @?= ([acDispute2], [acDispute1]),
    testCase "a dispute row carries its deposit and opener" $
      seeded $ \pool -> do
        p <- runPg pool (listDisputes emptyDisputeFilter {disputeFilterResolved = Just False} Desc page1)
        map (\d -> (disputeRowDeposit d, disputeRowOpenedBy d, disputeRowTarget d)) (pageItems p)
          @?= [(5_000_000, acBob, acAtt1)]
  ]
  where
    listed pool f = map disputeRowId . pageItems <$> runPg pool (listDisputes f Desc page1)

paginationTests :: [TestTree]
paginationTests =
  [ -- The clamp, pure. limit=0 has an obvious intended meaning and is served as 1 rather than
    -- refused, and the APPLIED value is what the envelope reports.
    testCase "limit 0 clamps to 1 and limit above the ceiling clamps to it" $ do
      normalizeLimitOffset jsonBounds (Just 0) Nothing @?= Right (1, 0)
      normalizeLimitOffset jsonBounds (Just 9999) Nothing @?= Right (200, 0)
      normalizeLimitOffset jsonBounds Nothing (Just (-5)) @?= Right (50, 0),
    testCase "a limit of 0 serves one row, and the envelope reports the applied limit" $
      seeded $ \pool -> do
        (lim, off) <- either (assertFailure . show) pure (normalizeLimitOffset jsonBounds (Just 0) Nothing)
        p <- runPg pool (listProfiles emptyAttestProfileFilter (ProfilesOrderByRegisteredAt, Asc) (lim, off))
        (length (pageItems p), pageLimit p, pageTotal p) @?= (1, 1, Just 5),
    -- An offset past the end is an empty page with the REAL total, not a total of zero: the count
    -- is over the predicate, never over the page.
    testCase "an offset past the end is an empty page with the full total" $
      seeded $ \pool -> do
        p <- runPg pool (listProfiles emptyAttestProfileFilter (ProfilesOrderByRegisteredAt, Asc) (50, 500))
        (pageItems p, pageTotal p, pageOffset p) @?= ([], Just 5, 500),
    testCase "paging through with limit 2 yields every row exactly once" $
      seeded $ \pool -> do
        let readPage off =
              map attestProfileName . pageItems
                <$> runPg pool (listProfiles emptyAttestProfileFilter (ProfilesOrderByName, Asc) (2, off))
        a <- readPage 0
        b <- readPage 2
        c <- readPage 4
        d <- readPage 6
        (a <> b <> c <> d) @?= ["Alice", "AliceScript", "Bob", "Nobody", "Orgsson"],
    testCase "a total is counted over the predicate, not over the page" $
      seeded $ \pool -> do
        p <-
          runPg
            pool
            ( listProfiles
                emptyAttestProfileFilter {attestProfileFilterClaimed = Just True}
                (ProfilesOrderByName, Asc)
                (1, 0)
            )
        (length (pageItems p), pageTotal p) @?= (1, Just 4)
  ]
