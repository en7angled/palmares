{-# LANGUAGE OverloadedStrings #-}

-- | Reads over the three @palmares_attest@ projection tables: profiles, attestations, disputes.
--
-- This is the attestation half of the read surface. "Query.Gov" is the governance half, and the
-- two are kept apart because they read different things in different ways: governance comes from
-- @palmares@ views over db-sync, where a view's column list is the contract, while these three
-- tables are @persistent@ entities that @attest-sync@ owns and writes.
--
-- Four decisions are load-bearing, in descending order of how much a reader will wonder about
-- them.
--
-- __1. @rawSql \"SELECT ??\"@, not @row_to_json@.__ "Query.Gov" projects one
-- @row_to_json(...)::text@ per statement and lets the DTO's @FromJSON@ decode it, because a view
-- column is text and a renamed column should fail NAMING the field. That shape is wrong here:
-- every interesting column in these tables is written through
-- @Database.Persist.TH.derivePersistFieldJSON@, so @profile_id@ holds the five characters
-- @\"abc\"@ — a JSON document — and not @abc@. A @row_to_json@ projection would publish each of
-- those twice-encoded, and the fix would be a quote-stripping cast per column, in SQL, duplicating
-- codecs that already exist. @??@ hands the row to persistent's own decoders instead: the exact
-- ones @attest-sync@ wrote it with, so a projection cannot be decoded differently from the way it
-- was stored. The parameters are bound the same way, through 'toPersistValue', which is why a
-- 'Core.ProfileRefAC' in a @WHERE@ matches the stored string without this module knowing how an
-- asset class is spelled.
--
-- __2. The table names are schema-qualified, and the tables are never aliased.__
-- 'QueryAppMonad.runRead' pins a statement timeout and nothing else, and @sql\/050_roles.sql@
-- leaves @palmares@ FIRST on the role's @search_path@ — so a bare @profile_projection@ resolves
-- to whatever @palmares@ happens to hold, which is the class of bug @Palmares.Storage@'s
-- @attestSchema@ comment documents. The alias is impossible rather than merely unused: @??@
-- expands to @\"profile_projection\".\"created_at_slot\", …@, the table's own name, so
-- @FROM palmares_attest.profile_projection p@ would not resolve. Hence the qualified @FROM@ with
-- the default relation name, and column references written out in full.
--
-- __3. Every statement is parameterised.__ The only text this module splices into SQL comes from
-- its own module-level constants and from a total function over a closed @*OrderBy@ enum
-- ('profileSortSpec', 'attestationSortSpec'). No request value reaches a clause, not even inside
-- a @LIKE@ pattern: 'Query.Common.likePat' escapes the user's @%@ and @_@ and the result is bound.
--
-- __4. The credential lookup accepts CIP-129 only.__ See 'canonicalGovCredential'.
module Query.Attest
  ( -- * The credential codec, strict
    canonicalGovCredential,
    credentialIsScript,

    -- * The CIP-68 pair, read backwards
    profileRefOfUserToken,

    -- * Profiles
    profileSortSpec,
    listProfiles,
    profileById,

    -- * Attestations
    attestationSortSpec,
    subjectTrackRecordSortSpec,
    -- | Exported for @UnitTests.QueryHardening@, the same reason "Query.Gov" exports @drepWhere@
    -- and @voteBaseWhere@: the clause this builds is where @issuer=@ stops attributing an
    -- unconsented @credential_withdrawal@ to the profile it names, and that is a property of the
    -- SQL rather than of a row, so it is pinned without a database.
    attestationWhere,
    listAttestations,
    attestationById,

    -- * The level-1 anchor, confronted with the index — ADR 0008
    resolveLevelOneAnchor,
    -- | Exported for the same reason: the verdict is a decision about what the two joins found, and
    -- it is the line that was wrong first — @resolved@ off @actionFound@ alone would publish "this
    -- payment happened" for a real action paired with an address it never paid.
    anchorStatusOf,

    -- * Disputes
    inlineDisputeLimit,
    listDisputes,
    disputeById,
  )
where

import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Database.Persist (Entity (..), PersistField, PersistValue, entityVal, toPersistValue)
import Database.Persist.Sql (Single (..), SqlPersistT, rawSql)
import Palmares.DomainTypes.Core.Ids (parseCredentialRoleCip129, parseGovActionIdCip129, renderCredentialRoleCip129)
import Palmares.DomainTypes.Core.Types qualified as Core
import Palmares.DomainTypes.Transfer.Filters
  ( AttestProfileFilter (..),
    AttestationRecordFilter (..),
    DisputeFilter (..),
  )
import Palmares.DomainTypes.Transfer.OrderBy
  ( AttestationsOrderBy (..),
    ProfilesOrderBy (..),
    SortOrder (..),
  )
import Palmares.DomainTypes.Transfer.QueryResponses
  ( AnchorWithdrawal (..),
    AttestProfileRow (..),
    AttestationDetailResponse (..),
    AttestationRow (..),
    DisputeRow (..),
    ResolvedLevelOneAnchor (..),
  )
import Palmares.Storage
  ( AttestationProjection (..),
    DisputeProjection (..),
    ProfileProjection (..),
  )
import Palmares.WebAPI.Envelope (Page (..))
import Query.Common (Limit, Offset, SortSpec (..), likePat, orderClause)
import Servant (FromHttpApiData (..))

-- ---------------------------------------------------------------------------------------------

-- * The credential codec, strict

-- | The canonical CIP-129 spelling of a governance credential, in __any of the three claimable
-- roles__, or 'Nothing'.
--
-- __This is the endpoint the word \"verified\" rests on, so it is deliberately not lenient.__
-- 'parseCredentialRoleCip129' accepts only an identifier that carries a header byte whose role
-- agrees with its HRP, which is exactly the set this lookup can answer about:
--
--   * @drep1y…@ \/ @drep1yw…@ (header @0x22@\/@0x23@) — accepted;
--   * @cc_cold1z…@ \/ @cc_cold1zw…@ (header @0x12@\/@0x13@) — accepted;
--   * @cc_hot1q…@ \/ @cc_hot1qw…@ (header @0x02@\/@0x03@) — accepted;
--   * @drep1…@ (CIP-105, the bare 28-byte hash) — __refused__;
--   * 56 hex characters — __refused__.
--
-- CIP-105 and bare hex carry no header byte and @drep@ is the HRP for both credential kinds, so
-- neither can say whether the credential is a key or a script. Accepting one would mean picking a
-- header byte to compare against the stored string — and picking the key byte, which is what
-- @FromHttpApiData Core.DRepId@ does for the governance routes, would silently report every
-- script DRep as a key DRep and find no claim for the script profile that exists. The governance
-- routes can afford that normalisation because they go on to resolve the row by its 28-byte hash
-- and re-render the id from @drep_hash.has_script@; there is no such row here. The column holds
-- exactly what the datum claimed, which is what 'Palmares.TxBuilding.Conversions.claimCredentialToText'
-- produced, which is CIP-129.
--
-- __THE THREE ROLES, and this function used to accept one of them.__ It was @canonicalDrepCredential@
-- over 'Palmares.DomainTypes.Core.Ids.parseDrepIdAny', whose HRP table is @drep@ alone — so a
-- committee credential was answered @400 invalid_drep_id@, \"Not a DRep identifier\", which is
-- literally true of a perfectly good @cc_cold1…@ and tells the caller nothing. ADR 0006 settles
-- that all three roles are claimable (@ClaimedDRep@ | @ClaimedCCCold@ | @ClaimedCCHot@, and the hot
-- one deliberately included because the claim\/withdrawal chain already handles rotation), the write
-- side accepts all three through 'parseCredentialRoleCip129', and the projection stores whatever
-- 'Palmares.TxBuilding.Conversions.claimCredentialToText' rendered — @cc_cold1…@ for a committee
-- cold claim. So the read side was refusing to look up a row it already held. Measured against the
-- deployed binary before the change: @\/profiles\/by-credential\/\<cc_cold1…\>@ and @\<cc_hot1…\>@
-- both answered @400 invalid_drep_id@.
--
-- Going through the parse and back out through 'renderCredentialRoleCip129' rather than comparing
-- the request text is what makes the match canonical in two senses: an upper-case or otherwise
-- non-canonical bech32 spelling of the same credential still finds its profile, and the HRP is
-- re-derived from the header byte rather than echoed — so a @drep1…@ carrying a committee header,
-- which 'parseCredentialRoleCip129' refuses outright, can never be silently matched against a
-- committee row.
canonicalGovCredential :: Text -> Maybe Text
canonicalGovCredential t =
  (\(role, isScript, raw) -> renderCredentialRoleCip129 role isScript raw)
    <$> parseCredentialRoleCip129 t

-- | Whether a stored credential is a script credential, from its header byte.
--
-- 'Nothing' for anything that does not carry one, which for a value written by
-- 'Palmares.TxBuilding.Conversions.claimCredentialToText' cannot happen — so a 'Nothing' beside a
-- non-null @credential@ means the column holds something that writer did not produce, and is
-- published as \"unknown\" rather than guessed.
--
-- __It had the same single-role bug as the lookup above__, and here it was silent rather than a
-- 400: over @parseDrepIdAny@ this answered 'Nothing' for every @cc_cold1…@ and @cc_hot1…@ in the
-- column, so a committee profile's @credential_is_script@ was published as \"unknown\" — the one
-- field @AttestProfileRow@'s own documentation promises a verification UI will never have to guess.
-- 'parseCredentialRoleCip129' reads the byte for all three roles.
credentialIsScript :: Text -> Maybe Bool
credentialIsScript t = (\(_, isScript, _) -> isScript) <$> parseCredentialRoleCip129 t

-- ---------------------------------------------------------------------------------------------

-- * The CIP-68 pair, read backwards

-- | The profile reference asset class that a CIP-68 __user__ token names, or 'Nothing'.
--
-- __This is the only thing a connected wallet holds.__ A profile is identified everywhere in this
-- API by its REFERENCE token — @\<policy\>.000643b0\<hash\>@, the one locked at the profiles
-- validator with the datum — and the token that lands in the owner's wallet is the USER half,
-- @\<policy\>.000de140\<hash\>@. Nothing on either service accepted a wallet-held identifier, so
-- \"which profile does my wallet own\" had no route at all: the documented workaround
-- (@docs\/usecases\/api-screen-map.md@ §5.2) was @wallet.getAssets()@, filter by the policy id from
-- @\/status.attestation.policy_id@, __reconstruct the reference name in the browser__, then
-- @GET \/profiles\/{that}@. This function is that reconstruction, moved to the side that owns the
-- derivation.
--
-- __Why it is a four-byte swap and not a hash.__ CIP-67 puts a 4-byte label in front of a shared
-- 28-byte name, and 'Palmares.Onchain.CIP68.generateRefAndUserTN' builds both halves from the same
-- bytes: @refTokenPrefixBS \<\> bs@ and @userTokenPrefixBS \<\> bs@. So the two differ in their
-- first four bytes and in nothing else, and going from one to the other needs no secret, no hash
-- and no chain read.
--
-- __Why the two labels are spelled here rather than imported.__ They live in @onchain-lib@, which
-- query-api deliberately does not depend on — the cabal stanza says so in a comment: \"No
-- atlas-cardano and no plutus-ledger-api: this service reads @palmares@ views over db-sync and
-- never queries the chain\". Importing 'Palmares.Onchain.CIP68' to read two constants would put
-- @plutus-ledger-api@ on a public read path. The cost is a second copy of two numbers, and it is
-- paid down by @UnitTests.QueryHardening@, which pins both against CIP-67's published values (100
-- and 222) and asserts that an attestation id and a dispute id — private-use labels 1 and 2, which
-- a wallet may well also hold — are refused rather than derived from. A divergence from
-- @Palmares.Onchain.CIP68@ therefore fails a test rather than returning somebody else's profile.
--
-- 'Nothing' for anything that is not a two-part asset class whose name begins with the user label:
-- the reference token itself (label @000643b0@), an attestation id (private-use label 1), a dispute
-- id (label 2), @lovelace@, or any other asset the wallet happens to hold. The handler serves that
-- as @400 invalid_asset_class@, which is a true statement about the input and the only reachable
-- site for that code in this service.
profileRefOfUserToken :: Text -> Maybe Core.ProfileRefAC
profileRefOfUserToken raw = case T.splitOn "." (T.toLower (T.strip raw)) of
  [policy, name]
    | Just rest <- T.stripPrefix cip67UserLabelHex name ->
        -- Re-parsed rather than constructed, so the policy id is validated by Atlas's own codec —
        -- the same one the `{profile-id}` capture uses — and this function cannot manufacture an
        -- asset class the rest of the API would not have accepted.
        either (const Nothing) Just (parseUrlPiece (policy <> "." <> cip67RefLabelHex <> rest))
  _ -> Nothing

-- | CIP-67 label 222, the user half of a CIP-68 pair. Mirrors @userTokenPrefixBS@.
cip67UserLabelHex :: Text
cip67UserLabelHex = "000de140"

-- | CIP-67 label 100, the reference half. Mirrors @refTokenPrefixBS@.
cip67RefLabelHex :: Text
cip67RefLabelHex = "000643b0"

-- ---------------------------------------------------------------------------------------------

-- * Plumbing

profileTable, attestationTable, disputeTable :: Text
profileTable = "palmares_attest.profile_projection"
attestationTable = "palmares_attest.attestation_projection"
disputeTable = "palmares_attest.dispute_projection"

-- | A clause with one bound parameter, contributed only when the filter value is present.
one :: (PersistField a) => Text -> Maybe a -> [(Text, [PersistValue])]
one sql = maybe [] (\v -> [(sql, [toPersistValue v])])

-- | A clause with no parameter at all — an @IS NULL@ test, where the predicate IS the filter.
flag :: Text -> Text -> Maybe Bool -> [(Text, [PersistValue])]
flag whenTrue whenFalse = maybe [] (\b -> [(if b then whenTrue else whenFalse, [])])

-- | An @IN@ clause over a repeatable parameter.
--
-- An EMPTY list is NO FILTER rather than \"match nothing\", the same reading every governance
-- list takes: asking for no particular kind is asking for any kind, and it is what makes a UI's
-- \"clear filters\" button work without a special case.
inList :: (PersistField a) => Text -> [a] -> [(Text, [PersistValue])]
inList col vs
  | null vs = []
  | otherwise =
      [ ( col <> " IN (" <> T.intercalate ", " (map (const "?") vs) <> ")",
          map toPersistValue vs
        )
      ]

-- | Join clause fragments with @AND@, keeping each fragment's parameters in clause order.
--
-- Order matters and is not incidental: @rawSql@ fills @?@ positionally, so the parameter list has
-- to be concatenated in exactly the order the clauses were rendered. Both come out of one pass
-- here so they cannot be maintained apart.
conjoin :: [[(Text, [PersistValue])]] -> (Text, [PersistValue])
conjoin groups
  | null cs = ("", [])
  | otherwise = (" WHERE " <> T.intercalate " AND " (map fst cs), concatMap snd cs)
  where
    cs = concat groups

-- | The total over the SAME predicate the page was read with.
--
-- The @WHERE@ fragment and its parameters are passed in rather than rebuilt, because a total
-- counted under a different predicate than the rows is the defect that makes a paginator
-- disagree with itself (F-17).
countIn :: Text -> Text -> [PersistValue] -> SqlPersistT IO Int
countIn table whereSql params = do
  rows <- rawSql ("SELECT count(*)::int FROM " <> table <> whereSql) params
  pure (case rows of (Single n : _) -> n; [] -> 0)

-- ---------------------------------------------------------------------------------------------

-- * Profiles

-- | The ordering each @order_by@ value means. Closed and total, which is the security property:
-- 'orderClause' splices these column names into an @ORDER BY@, and the only way a name gets there
-- is through this function.
--
-- The tiebreaker is the surrogate primary key, which is total by construction — without one, two
-- profiles sharing a sort key (two rows in the same slot, two identical names) may come back in
-- either order on either page, and a client paging through them skips some and sees others twice.
--
-- @name@ and @description@ sort LOWERCASED so the order matches the case-insensitive search that
-- found the rows. Nothing is @NULLS LAST@: no sorted column here is nullable.
profileSortSpec :: ProfilesOrderBy -> SortSpec
profileSortSpec ob = case ob of
  ProfilesOrderById -> SortSpec "profile_projection.profile_id" False tie
  ProfilesOrderByName -> SortSpec "lower(profile_projection.profile_name)" False tie
  ProfilesOrderByDescription -> SortSpec "lower(profile_projection.profile_description)" False tie
  ProfilesOrderByType -> SortSpec "profile_projection.profile_type" False tie
  ProfilesOrderByRegisteredAt -> SortSpec "profile_projection.created_at_slot" False tie
  where
    tie = "profile_projection.id"

-- | The @WHERE@ fragment and its parameters.
profileWhere :: AttestProfileFilter -> (Text, [PersistValue])
profileWhere f =
  conjoin
    [ inList "profile_projection.profile_type" (attestProfileFilterKinds f),
      one "profile_projection.profile_credential = ?" (attestProfileFilterCredential f),
      flag
        "profile_projection.profile_credential IS NOT NULL"
        "profile_projection.profile_credential IS NULL"
        (attestProfileFilterClaimed f),
      textSearch (attestProfileFilterQ f)
    ]
  where
    -- The pattern is BOUND, not spliced, and 'likePat' has already escaped any % or _ the user
    -- typed, so searching for "100%" matches the string and not every row.
    textSearch =
      maybe
        []
        ( \t ->
            [ ( "(lower(profile_projection.profile_name) LIKE ? \
                \OR lower(profile_projection.profile_description) LIKE ?)",
                [toPersistValue (likePat t), toPersistValue (likePat t)]
              )
            ]
        )

-- | One page of profiles, with a total over the same predicate.
listProfiles ::
  AttestProfileFilter ->
  (ProfilesOrderBy, SortOrder) ->
  (Limit, Offset) ->
  SqlPersistT IO (Page AttestProfileRow)
listProfiles f (ob, so) (lim, off) = do
  rows <-
    rawSql
      ( "SELECT ?? FROM "
          <> profileTable
          <> whereSql
          <> " "
          <> orderClause (profileSortSpec ob) so
          <> " LIMIT ? OFFSET ?"
      )
      (params <> [toPersistValue lim, toPersistValue off])
  total <- countIn profileTable whereSql params
  pure (Page (map (toProfileRow . entityVal) rows) (Just total) lim off Nothing)
  where
    (whereSql, params) = profileWhere f

-- | One profile by its asset class. 'Nothing' is the handler's 404.
profileById :: Core.ProfileRefAC -> SqlPersistT IO (Maybe AttestProfileRow)
profileById pid = do
  rows <-
    rawSql
      ("SELECT ?? FROM " <> profileTable <> " WHERE profile_projection.profile_id = ? LIMIT 1")
      [toPersistValue pid]
  pure (case rows of (r : _) -> Just (toProfileRow (entityVal r)); [] -> Nothing)

toProfileRow :: ProfileProjection -> AttestProfileRow
toProfileRow p =
  AttestProfileRow
    { attestProfileId = profileProjectionProfileId p,
      attestProfileName = profileProjectionProfileName p,
      attestProfileDescription = profileProjectionProfileDescription p,
      attestProfileImageURI = profileProjectionProfileImageURI p,
      attestProfileKind = profileProjectionProfileType p,
      attestProfileCredential = profileProjectionProfileCredential p,
      -- Decoded from the stored identifier's header byte, never inferred: see 'credentialIsScript'.
      attestProfileCredentialIsScript = profileProjectionProfileCredential p >>= credentialIsScript,
      attestProfileSlot = profileProjectionCreatedAtSlot p,
      attestProfileBlockHash = profileProjectionCreatedAtHash p
    }

-- ---------------------------------------------------------------------------------------------

-- * Attestations

-- | The ordering each @order_by@ value means on @GET \/attestations@. Closed and total.
attestationSortSpec :: AttestationsOrderBy -> SortSpec
attestationSortSpec ob = case ob of
  AttestationsOrderById -> SortSpec "attestation_projection.attestation_id" False tie
  AttestationsOrderByDate -> SortSpec "attestation_projection.attestation_date" False tie
  AttestationsOrderBySubject -> SortSpec "attestation_projection.subject_profile_id" False tie
  AttestationsOrderByIssuer -> SortSpec "attestation_projection.issuer_profile_id" False tie
  AttestationsOrderByName -> SortSpec "lower(attestation_projection.attestation_name)" False tie
  where
    tie = "attestation_projection.id"

-- | @GET \/profiles\/{id}\/attestations@: accepted first, then newest.
--
-- One fixed ordering and no @order_by@ on that route, because the track record answers one
-- question — what does this profile's record say — and an unaccepted attestation is a claim the
-- subject has not acknowledged. Sorting those to the top would make a page of unacknowledged
-- claims look like a record.
--
-- The three columns are spelled as one 'SortSpec' with a two-column tiebreaker, the shape
-- 'Query.Gov.withdrawalSortSpec' also needs: @orderClause@ appends the tiebreaker ascending, so
-- @is_accepted DESC@ is followed by @attestation_date DESC, id ASC@. The direction of the date is
-- fixed inside the tiebreaker on purpose — @sort_order@ flips only @is_accepted@, and a track
-- record read oldest-first should still show the acknowledged rows together.
subjectTrackRecordSortSpec :: SortSpec
subjectTrackRecordSortSpec =
  SortSpec
    "attestation_projection.is_accepted"
    False
    "attestation_projection.attestation_date DESC, attestation_projection.id"

-- | The @WHERE@ fragment and its parameters.
attestationWhere :: AttestationRecordFilter -> (Text, [PersistValue])
attestationWhere f =
  conjoin
    [ one "attestation_projection.subject_profile_id = ?" (attestationRecordFilterSubject f),
      issuedBy (attestationRecordFilterIssuer f),
      inList "attestation_projection.attestation_kind" (attestationRecordFilterKinds f),
      one "attestation_projection.is_accepted = ?" (attestationRecordFilterAccepted f),
      -- Bound as UTCTime against a timestamptz column: the same PersistUTCTime the GYTime
      -- instance writes, so the comparison is on the column's own type and stays indexable.
      one "attestation_projection.attestation_date >= ?" (attestationRecordFilterDateFrom f),
      one "attestation_projection.attestation_date <= ?" (attestationRecordFilterDateTo f)
    ]
  where
    -- `issuer=` means "what this profile has SAID", and on one kind the column does not mean that —
    -- so this clause is narrower than an equality test, and the difference is a correctness fix
    -- rather than a filter refinement.
    --
    -- `Mf` IS CONDITIONAL, and `CredentialWithdrawal` is its one exemption (minting policy,
    -- ADR 0003). For every other kind the issuer's user NFT must be spent in the minting
    -- transaction, which is what makes `issuer_profile_id` mean "this profile said so". A
    -- withdrawal is the one record the profile must NOT be asked for, because the case it exists
    -- for is a profile that claimed somebody else's credential and whose token is held by whoever
    -- did it. The on-chain comment states the consequence in as many words: on the two credential
    -- kinds `attestationIssuer` is STRUCTURAL — `Mc1` forces it to equal the subject, so it names
    -- the profile the record is ABOUT and "makes no claim about who acted".
    --
    -- The read layer was making that claim anyway. `issuer` is documented on GET /attestations as
    -- "an issuance history", so a withdrawal minted by the credential holder alone was served as
    -- something the named profile had issued — and the chain cannot be changed to prevent it (the
    -- protocol is deployed with frozen hashes), which puts the fix exactly here. It is the same
    -- division of labour `Palmares.Storage.deriveProfileCredential` already documents for a
    -- withdrawal naming the wrong credential: "the chain permits such a record (Mc3 asks only the
    -- named credential to consent), so the read layer has to be the one that ignores it".
    --
    -- THE CONSENT TEST IS `is_accepted`, which is the one this surface already uses and not a new
    -- signal. `A5` asks the SUBJECT to spend its user NFT to accept, and `Mc1` makes subject and
    -- issuer the same profile on a credential record — so an ACCEPTED withdrawal is one the named
    -- profile put its own token behind, and stays in its issuance history. Only the unaccepted one
    -- leaves, and it leaves nothing invisible: `Mc1` also means the row is reachable with identical
    -- content through `subject=`, GET /profiles/{id}/attestations and GET /attestations/{id}, where
    -- the profile is the thing the record is about rather than its author. Nothing is deleted or
    -- hidden, which is ADR 0003's whole rule.
    issuedBy =
      maybe
        []
        ( \pid ->
            [ ( "attestation_projection.issuer_profile_id = ? \
                \AND NOT (attestation_projection.attestation_kind = ? \
                \AND attestation_projection.is_accepted = false)",
                [toPersistValue pid, toPersistValue Core.CredentialWithdrawal]
              )
            ]
        )

-- | One page of attestations, with a total over the same predicate.
--
-- The 'SortSpec' is passed in rather than derived, because the two routes this serves order
-- differently: @\/attestations@ by its @order_by@, @\/profiles\/{id}\/attestations@ by
-- 'subjectTrackRecordSortSpec'. One query either way, so the track record and the global list
-- cannot disagree about a row.
listAttestations ::
  AttestationRecordFilter ->
  (SortSpec, SortOrder) ->
  (Limit, Offset) ->
  SqlPersistT IO (Page AttestationRow)
listAttestations f (spec, so) (lim, off) = do
  rows <-
    rawSql
      ( "SELECT ?? FROM "
          <> attestationTable
          <> whereSql
          <> " "
          <> orderClause spec so
          <> " LIMIT ? OFFSET ?"
      )
      (params <> [toPersistValue lim, toPersistValue off])
  total <- countIn attestationTable whereSql params
  pure (Page (map (toAttestationRow . entityVal) rows) (Just total) lim off Nothing)
  where
    (whereSql, params) = attestationWhere f

-- | One attestation with its disputes inlined. 'Nothing' is the handler's 404.
--
-- Both reads happen in the caller's one 'QueryAppMonad.runRead' transaction, so the attestation
-- and its challenges are the same snapshot: a composite assembled from two transactions can show
-- an attestation from one moment beside a dispute list from another, which on this endpoint means
-- showing an undisputed attestation that is disputed.
attestationById :: Core.AttestationAC -> SqlPersistT IO (Maybe AttestationDetailResponse)
attestationById aid = do
  rows <-
    rawSql
      ( "SELECT ?? FROM "
          <> attestationTable
          <> " WHERE attestation_projection.attestation_id = ? LIMIT 1"
      )
      [toPersistValue aid]
  case rows of
    [] -> pure Nothing
    (r : _) -> do
      ds <- disputesFor aid
      anchor <- resolveLevelOneAnchor (otherMetadataOf (entityVal r))
      pure (Just (AttestationDetailResponse (toAttestationRow (entityVal r)) ds anchor))

-- | The caller-supplied metadata of a projected attestation, as a plain association list.
otherMetadataOf :: AttestationProjection -> [(Text, Text)]
otherMetadataOf =
  maybe [] Core.fromAttestationOtherMetadataJson . attestationProjectionOtherMetadata

-- | Confront an attestation's level-1 anchor with the index — __ADR 0008__.
--
-- __Why the read layer resolves it at all.__ Nothing on chain checks that the fact exists, by the
-- specification's own decision: a treasury withdrawal is not an addressable UTxO, so there is no
-- reference input to verify against. The pointer is therefore only ever as good as the moment it is
-- read, and the requirement is phrased as "the API marks explicitly whether the pointer resolves"
-- rather than "the API shows resolved anchors".
--
-- __Four outcomes, and the parse happens TWICE on purpose.__ The write API refuses a malformed
-- anchor, but a hand-built transaction skips the write API entirely, so the shape is checked again
-- here. A malformed anchor is published as @malformed@ with the raw keys rather than dropped: the
-- datum permanently says this attestation is about that payment, and publishing @null@ would make
-- the API claim the attestation is unanchored — the one answer that is a lie about a record nobody
-- can change.
--
-- One statement serves both anchor kinds. An action-only anchor binds @NULL@ for the address, and
-- @stake_address = NULL@ is never true, so the withdrawal join simply finds nothing — which is the
-- right answer, not a special case: that anchor points at an action, not at a payment.
resolveLevelOneAnchor :: [(Text, Text)] -> SqlPersistT IO (Maybe ResolvedLevelOneAnchor)
resolveLevelOneAnchor entries = case Core.parseLevelOneAnchor entries of
  Left _ -> pure (Just (malformed (raw Core.levelOneAnchorActionKey) (raw Core.levelOneAnchorAddressKey)))
  Right Nothing -> pure Nothing
  Right (Just a) -> case parseGovActionIdCip129 (Core.anchorGovActionId a) of
    -- Unreachable through 'Core.parseLevelOneAnchor', which already accepted this id. Written as
    -- `malformed` rather than as an `error` so that a future change to either parser degrades to a
    -- published verdict instead of a 500 on an attestation detail page.
    Left _ -> pure (Just (malformed (Just (Core.anchorGovActionId a)) (Core.anchorStakeAddress a)))
    Right (txHashHex, ix) -> do
      rows <-
        rawSql
          "SELECT ga.gov_action_id IS NOT NULL, tw.stake_address IS NOT NULL, \
          \       tw.amount, tw.enacted_epoch, tw.paid_heuristic \
          \FROM (SELECT 1) one \
          \LEFT JOIN palmares.gov_action ga \
          \       ON ga.tx_hash = decode(?, 'hex') AND ga.index = ? \
          \LEFT JOIN palmares.treasury_withdrawal tw \
          \       ON tw.gov_action_id = ga.gov_action_id AND tw.stake_address = ?"
          [ toPersistValue txHashHex,
            toPersistValue (fromIntegral ix :: Int),
            toPersistValue (Core.anchorStakeAddress a)
          ]
      -- The LEFT JOIN over `(SELECT 1)` always returns exactly one row, so the empty case cannot
      -- arise from the data — only from a connection that died mid-statement, where `unresolved` is
      -- the honest answer and a crash on an attestation page is not.
      let (actionFound, withdrawalFound, amount, epoch, paid) = case rows of
            (Single af, Single wf, Single am, Single ep, Single pd) : _ -> (af, wf, am, ep, pd)
            [] -> (False, False, Nothing, Nothing, Nothing)
      pure . Just $
        ResolvedLevelOneAnchor
          { resolvedAnchorGovActionId = Just (Core.anchorGovActionId a),
            resolvedAnchorStakeAddress = Core.anchorStakeAddress a,
            resolvedAnchorStatus = anchorStatusOf actionFound withdrawalFound (Core.anchorStakeAddress a),
            resolvedAnchorWithdrawal =
              if withdrawalFound
                then
                  Just
                    AnchorWithdrawal
                      { anchorWithdrawalAmount = fromMaybe 0 amount,
                        anchorWithdrawalEnactedEpoch = epoch,
                        anchorWithdrawalPaidHeuristic = fromMaybe False paid
                      }
                else Nothing
          }
  where
    raw k = lookup k entries
    malformed ga addr = ResolvedLevelOneAnchor ga addr Core.L1Malformed Nothing

-- | The verdict, as a function of what the two joins found and whether an address was asked about.
--
-- __Extracted because this is the line that was wrong.__ The first version read @resolved@ off
-- @actionFound@ alone, which published @resolved@ for an anchor that gives BOTH keys and names a
-- payment nobody made: a real governance action paired with an address that action never paid. That
-- reads identically to an action-only anchor, so a UI would show "this payment happened" about a
-- payment that did not. @resolved@ means __what the client asked__ resolved, not that something did.
--
-- Pure and exported so the eight combinations can be pinned without seeding four db-sync tables to
-- manufacture a withdrawal — the defect was in the decision, not in the join.
anchorStatusOf :: Bool -> Bool -> Maybe Text -> Core.LevelOneAnchorStatus
anchorStatusOf actionFound withdrawalFound addr
  | actionFound && (isNothing addr || withdrawalFound) = Core.L1Resolved
  | otherwise = Core.L1Unresolved

toAttestationRow :: AttestationProjection -> AttestationRow
toAttestationRow a =
  AttestationRow
    { attestationRowId = attestationProjectionAttestationId a,
      attestationRowSubject = attestationProjectionSubjectProfileId a,
      attestationRowIssuer = attestationProjectionIssuerProfileId a,
      attestationRowKind = attestationProjectionAttestationKind a,
      attestationRowDate = attestationProjectionAttestationDate a,
      -- Both columns or neither, which is what the writer guarantees: it sets them from one
      -- `Maybe` pair. A half-set row could only come from a hand-written UPDATE, and reading it as
      -- "no period" is the safe answer — a period with one bound is not a period.
      attestationRowClaimedPeriod =
        case ( attestationProjectionClaimedPeriodFrom a,
               attestationProjectionClaimedPeriodTo a
             ) of
          (Just from, Just to) -> Just (from, to)
          _ -> Nothing,
      attestationRowCredential = attestationProjectionAttestationCredential a,
      attestationRowAccepted = attestationProjectionIsAccepted a,
      attestationRowName = attestationProjectionAttestationName a,
      attestationRowDescription = attestationProjectionAttestationDescription a,
      attestationRowImageURI = attestationProjectionAttestationImageURI a,
      attestationRowOtherMetadata =
        maybe [] Core.fromAttestationOtherMetadataJson (attestationProjectionOtherMetadata a),
      attestationRowSlot = attestationProjectionCreatedAtSlot a,
      attestationRowBlockHash = attestationProjectionCreatedAtHash a,
      attestationRowTxHash = attestationProjectionCreatedTxId a,
      attestationRowOutputIndex = attestationProjectionCreatedOutputIndex a
    }

-- ---------------------------------------------------------------------------------------------

-- * Disputes

-- | How many disputes @GET \/attestations\/{id}@ inlines.
--
-- A bound rather than the whole list, for the reason 'Query.Gov' caps the certificate history it
-- inlines at fifty: a dispute costs a deposit, so a thousand against one attestation is not a
-- shape to expect, but it is a shape a funded adversary can create and an inline list has no
-- @offset@ to escape with. Past the bound, @GET \/disputes?target=…@ is the paged view.
inlineDisputeLimit :: Int
inlineDisputeLimit = 50

-- | The disputes against one attestation, newest first, bounded by 'inlineDisputeLimit'.
disputesFor :: Core.AttestationAC -> SqlPersistT IO [DisputeRow]
disputesFor aid = do
  rows <-
    rawSql
      ( "SELECT ?? FROM "
          <> disputeTable
          <> " WHERE dispute_projection.target_attestation_id = ? "
          <> orderClause disputeSortSpec Desc
          <> " LIMIT ?"
      )
      [toPersistValue aid, toPersistValue inlineDisputeLimit]
  pure (map (toDisputeRow . entityVal) rows)

-- | @GET \/disputes@ orders by when the dispute was opened, with the surrogate key as tiebreaker.
--
-- There is no @order_by@ on that route and so no enum: the list has one chronology, and a second
-- ordering would be a control with no screen behind it.
disputeSortSpec :: SortSpec
disputeSortSpec = SortSpec "dispute_projection.opened_at" False "dispute_projection.id"

-- | The @WHERE@ fragment and its parameters.
disputeWhere :: DisputeFilter -> (Text, [PersistValue])
disputeWhere f =
  conjoin
    [ one "dispute_projection.target_attestation_id = ?" (disputeFilterTarget f),
      -- `resolved` is presence of a verdict, not a verdict value: the column is NULL while the
      -- dispute is open.
      flag
        "dispute_projection.verdict IS NOT NULL"
        "dispute_projection.verdict IS NULL"
        (disputeFilterResolved f)
    ]

-- | One page of disputes, with a total over the same predicate.
listDisputes :: DisputeFilter -> SortOrder -> (Limit, Offset) -> SqlPersistT IO (Page DisputeRow)
listDisputes f so (lim, off) = do
  rows <-
    rawSql
      ( "SELECT ?? FROM "
          <> disputeTable
          <> whereSql
          <> " "
          <> orderClause disputeSortSpec so
          <> " LIMIT ? OFFSET ?"
      )
      (params <> [toPersistValue lim, toPersistValue off])
  total <- countIn disputeTable whereSql params
  pure (Page (map (toDisputeRow . entityVal) rows) (Just total) lim off Nothing)
  where
    (whereSql, params) = disputeWhere f

-- | One dispute by its asset class. 'Nothing' is the handler's 404.
--
-- The same shape as 'profileById', and it exists for the reason a dispute needs a URL of its own:
-- a notification or a shared link points at ONE dispute, and before this the only ways to reach it
-- were @GET \/disputes?target=…@ (the list, which needs the attestation id as well) and
-- @GET \/attestations\/{id}@ (which inlines at most 'inlineDisputeLimit' of them, so a dispute
-- past the bound was unreachable by id at all). @dispute_not_found@ was declared and unreachable;
-- this is its site.
--
-- Typed 'Core.AttestationAC' because 'Palmares.DomainTypes.Transfer.QueryResponses.DisputeRow'
-- types @disputeRowId@ that way and both are @GYAssetClass@ — not because a dispute id is an
-- attestation id. ADR 0006 gives a dispute its own CIP-67 label (private-use label 2) and an
-- attestation label 1, so the two are distinguishable by value; the capture accepts either
-- spelling and this query answers for whichever one is actually a dispute, which is a 404 for an
-- attestation id rather than a wrong row.
disputeById :: Core.AttestationAC -> SqlPersistT IO (Maybe DisputeRow)
disputeById did = do
  rows <-
    rawSql
      ("SELECT ?? FROM " <> disputeTable <> " WHERE dispute_projection.dispute_id = ? LIMIT 1")
      [toPersistValue did]
  pure (case rows of (r : _) -> Just (toDisputeRow (entityVal r)); [] -> Nothing)

toDisputeRow :: DisputeProjection -> DisputeRow
toDisputeRow d =
  DisputeRow
    { disputeRowId = disputeProjectionDisputeId d,
      disputeRowTarget = disputeProjectionTargetAttestationId d,
      disputeRowOpenedBy = disputeProjectionOpenedByProfileId d,
      disputeRowOpenedAt = disputeProjectionOpenedAt d,
      disputeRowStaleAfter = disputeProjectionStaleAfter d,
      disputeRowDeposit = disputeProjectionDeposit d,
      disputeRowVerdict = disputeProjectionVerdict d,
      disputeRowName = disputeProjectionDisputeName d,
      disputeRowDescription = disputeProjectionDisputeDescription d,
      disputeRowImageURI = disputeProjectionDisputeImageURI d,
      disputeRowSlot = disputeProjectionCreatedAtSlot d,
      disputeRowBlockHash = disputeProjectionCreatedAtHash d
    }
