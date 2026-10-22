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
-- __4. The credential lookup accepts CIP-129 only.__ See 'canonicalDrepCredential'.
module Query.Attest
  ( -- * The credential codec, strict
    canonicalDrepCredential,
    credentialIsScript,

    -- * Profiles
    profileSortSpec,
    listProfiles,
    profileById,

    -- * Attestations
    attestationSortSpec,
    subjectTrackRecordSortSpec,
    listAttestations,
    attestationById,

    -- * Disputes
    inlineDisputeLimit,
    listDisputes,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Database.Persist (Entity (..), PersistField, PersistValue, entityVal, toPersistValue)
import Database.Persist.Sql (Single (..), SqlPersistT, rawSql)
import Palmares.DomainTypes.Core.Ids (drepIdCip129, parseDrepIdAny)
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
  ( AttestProfileRow (..),
    AttestationDetailResponse (..),
    AttestationRow (..),
    DisputeRow (..),
  )
import Palmares.Storage
  ( AttestationProjection (..),
    DisputeProjection (..),
    ProfileProjection (..),
  )
import Palmares.WebAPI.Envelope (Page (..))
import Query.Common (Limit, Offset, SortSpec (..), likePat, orderClause)

-- ---------------------------------------------------------------------------------------------

-- * The credential codec, strict

-- | The canonical CIP-129 spelling of a DRep credential, or 'Nothing'.
--
-- __This is the endpoint the word \"verified\" rests on, so it is deliberately not lenient.__
-- 'parseDrepIdAny' accepts three forms and reports whether the input carried a header byte;
-- only the CIP-129 form does, and this function accepts __only that case__:
--
--   * @drep1y…@ \/ @drep1yw…@ (CIP-129, 29 bytes, header @0x22@ or @0x23@) — accepted;
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
-- Going through the parse and back out through 'drepIdCip129' rather than comparing the request
-- text is what makes the match canonical: an upper-case or otherwise non-canonical bech32
-- spelling of the same credential still finds its profile, and nothing but a well-formed
-- credential reaches the query.
canonicalDrepCredential :: Text -> Maybe Text
canonicalDrepCredential t = case parseDrepIdAny t of
  Right (Just isScript, raw) -> Just (drepIdCip129 isScript raw)
  -- Right (Nothing, _) is CIP-105 or bare hex: well-formed, and not a CIP-129 credential.
  _ -> Nothing

-- | Whether a stored credential is a script credential, from its header byte.
--
-- 'Nothing' for anything that does not carry one, which for a value written by
-- 'Palmares.TxBuilding.Conversions.claimCredentialToText' cannot happen — so a 'Nothing' beside a
-- non-null @credential@ means the column holds something that writer did not produce, and is
-- published as \"unknown\" rather than guessed.
credentialIsScript :: Text -> Maybe Bool
credentialIsScript t = case parseDrepIdAny t of
  Right (Just isScript, _) -> Just isScript
  _ -> Nothing

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
      one "attestation_projection.issuer_profile_id = ?" (attestationRecordFilterIssuer f),
      inList "attestation_projection.attestation_kind" (attestationRecordFilterKinds f),
      one "attestation_projection.is_accepted = ?" (attestationRecordFilterAccepted f),
      -- Bound as UTCTime against a timestamptz column: the same PersistUTCTime the GYTime
      -- instance writes, so the comparison is on the column's own type and stays indexable.
      one "attestation_projection.attestation_date >= ?" (attestationRecordFilterDateFrom f),
      one "attestation_projection.attestation_date <= ?" (attestationRecordFilterDateTo f)
    ]

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
      pure (Just (AttestationDetailResponse (toAttestationRow (entityVal r)) ds))

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

toDisputeRow :: DisputeProjection -> DisputeRow
toDisputeRow d =
  DisputeRow
    { disputeRowId = disputeProjectionDisputeId d,
      disputeRowTarget = disputeProjectionTargetAttestationId d,
      disputeRowOpenedBy = disputeProjectionOpenedByProfileId d,
      disputeRowOpenedAt = disputeProjectionOpenedAt d,
      disputeRowDeposit = disputeProjectionDeposit d,
      disputeRowVerdict = disputeProjectionVerdict d,
      disputeRowName = disputeProjectionDisputeName d,
      disputeRowDescription = disputeProjectionDisputeDescription d,
      disputeRowImageURI = disputeProjectionDisputeImageURI d,
      disputeRowSlot = disputeProjectionCreatedAtSlot d,
      disputeRowBlockHash = disputeProjectionCreatedAtHash d
    }
