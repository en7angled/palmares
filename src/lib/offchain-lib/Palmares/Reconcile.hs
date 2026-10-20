{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The reconciliation primitive, the waiver file, the freshness guard and the report (F1 check 6).
--
-- __One comparison primitive, because all ten rows are the same shape:__ a keyed comparison. Two
-- maps keyed the same way; a key on one side only is a @membership@ divergence; a key on both is
-- handed to a field comparator that returns ONLY what differs. 'diffKeyed' is that, and R9's
-- multiset equality is it too, with the key being @(address, amount)@ and the value a count.
--
-- __The two sides are named @koios@ and @palmares@, never @expected@ and @actual@.__ That is not
-- style. A report that calls one side "expected" has already decided which index is right, and the
-- whole point of a parity check is that the answer is not known in advance — the delegation bug
-- this found was ours, and the gov-action lifecycle numbers that agree are agreed by both.
--
-- __Three exit codes and only three:__ 0 clean or explained, 1 unexplained, 3 aborted. __2 is
-- reserved for transport failure__ and is produced by the executable, never here: "Koios did not
-- answer" and "Koios answered something different" are different events and a caller must be able
-- to tell them apart without reading a log.
--
-- __A skipped row is the only path to exit 3.__ 'mkReport' returns 'ReportAborted' whenever any row
-- is 'RowSkipped', so a run that could not compare something cannot report a pass, and the caller
-- needs no abort branch of its own. One report constructor, so there is no second place for the
-- two to drift.
module Palmares.Reconcile
  ( -- * What is compared
    RowId (..),
    rowIdText,
    Divergence (..),
    diffKeyed,

    -- * Documented divergences
    ExceptionEntry (..),
    loadExceptions,
    applyExceptions,
    staleExceptions,

    -- * One row's outcome
    RowStatus (..),
    isSkipped,
    RowResult (..),
    mkRow,
    skippedRow,

    -- * Freshness
    Freshness (..),
    checkFreshness,

    -- * The two snapshots
    KoiosSnapshot (..),
    PalmaresSnapshot (..),
    PDRep (..),
    PAction (..),
    PCommittee (..),

    -- * The ten rows
    reconcileAll,
    readyMaxLagSeconds,

    -- * The pinned sample
    ReconcileSample (..),
    loadSample,

    -- * Recorded snapshots
    loadKoiosSnapshot,
    loadPalmaresSnapshot,
    mkPalmaresSnapshot,

    -- * The report
    ReportStatus (..),
    Report (..),
    mkReport,
    reportExitCode,
  )
where

import Control.Exception (IOException, try)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import Data.Aeson
  ( FromJSON (parseJSON),
    ToJSON (toJSON),
    Value (String),
    eitherDecodeFileStrict,
    object,
    withObject,
    withText,
    (.:),
    (.:?),
    (.=),
  )
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as M
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as S
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (Day, UTCTime)
import Data.Yaml qualified as Yaml
import GHC.Generics (Generic)
import Palmares.DomainTypes.Core.Types
  ( ChainPoint (..),
    DRepId (..),
    DRepStatus,
    GovActionType,
    Vote (..),
    VoterRole (..),
  )
import Palmares.DomainTypes.Transfer.QueryResponses
  ( CommitteeMemberSummary (..),
    CommitteeResponse (..),
    DRepSummary (..),
    EpochPowerPoint (..),
    GovActionDetailResponse (..),
    GovActionLifecycle (..),
    GovActionSummary (..),
    StatusResponse (..),
    SyncStatus (..),
    TreasuryWithdrawalRow (..),
    VoteRecord (..),
    VoteTally (..),
  )
import Palmares.Reconcile.Koios
import Palmares.Utils (jsonTag)
import System.FilePath ((</>))

-- ---------------------------------------------------------------------------------------------

-- * What is compared

-- | The ten reconciliation rows, named so a waiver file and a report can refer to one.
--
-- Numbered rather than named after what they compare, because the waiver file is a long-lived
-- artifact and a row's SUBJECT is easier to restate than its identity: an entry that says @R3@
-- keeps meaning the same row when the row's description is reworded. The catalogue of what each
-- one compares lives with 'Palmares.Reconcile.reconcileAll'.
data RowId = R1 | R2 | R3 | R4 | R5 | R6 | R7 | R8 | R9 | R10
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)

-- | A row id as the report and the waiver file spell it.
rowIdText :: RowId -> Text
rowIdText = T.pack . show

instance FromJSON RowId where
  parseJSON = withText "RowId" $ \t ->
    maybe (fail ("Palmares.Reconcile: not a row id: " <> T.unpack t <> " (expected R1..R10)")) pure $
      lookup t [(rowIdText r, r) | r <- [minBound .. maxBound]]

-- | One disagreement: which key, which field, and what each side said.
--
-- @field@ is @\"membership\"@ when the key itself is one-sided, which is why it is a 'Text' rather
-- than a sum type — a membership divergence and a field divergence are reported, waived and
-- counted identically, and giving them different shapes would mean two code paths for one idea.
--
-- Both values are 'Text' and both are rendered by the caller. A divergence is something a person
-- reads and then chases, so the rendering that makes it legible is the comparator's business.
data Divergence = Divergence
  { divergenceKey :: Text,
    divergenceField :: Text,
    divergenceKoios :: Text,
    divergencePalmares :: Text
  }
  deriving stock (Show, Eq, Ord, Generic)

-- | The only comparison primitive.
--
-- A key present on one side only becomes a @membership@ divergence. A key on both sides is handed
-- to the field comparator, which returns ONLY the fields that differ, as
-- @(field, koios, palmares)@ — returning every field and filtering afterwards would make every
-- comparator carry the same filter, and one of them would eventually carry it wrongly.
--
-- Divergences come out in ascending key order, so a report diffs cleanly against the previous run
-- and a reviewer reading two of them side by side is reading the same order.
diffKeyed ::
  (Ord k) =>
  -- | How to render a key in the report
  (k -> Text) ->
  -- | What differs between two values present on both sides
  (a -> b -> [(Text, Text, Text)]) ->
  -- | Koios's side
  Map k a ->
  -- | Our side
  Map k b ->
  [Divergence]
diffKeyed render cmp koios palmares =
  concatMap one (S.toAscList (S.union (M.keysSet koios) (M.keysSet palmares)))
  where
    one k = case (M.lookup k koios, M.lookup k palmares) of
      (Just a, Just b) -> [Divergence (render k) f ka pa | (f, ka, pa) <- cmp a b]
      (Just _, Nothing) -> [Divergence (render k) "membership" "present" "absent"]
      (Nothing, Just _) -> [Divergence (render k) "membership" "absent" "present"]
      -- Unreachable: k came from the union of the two key sets.
      (Nothing, Nothing) -> []

-- ---------------------------------------------------------------------------------------------

-- * Documented divergences

-- | One documented divergence, from @config\/reconcile-exceptions.yaml@.
--
-- An entry turns one divergence from @unexplained@ into @explained@. __It suppresses nothing
-- else:__ the divergence still appears in the report, under @explained@, with this entry's reason
-- beside it. A waiver that made a difference disappear would be a way to make the check pass by
-- editing a file.
--
-- @field@ omitted explains EVERY field of that key, which is the shape a legitimate waiver usually
-- has — "this DRep's whole row differs because Koios counts live and we count at the epoch" is one
-- decision, not six.
--
-- @reason@, @opened@ and @owner@ are all required, and that is the entry's whole value: an
-- undated, unowned, unexplained waiver is indistinguishable from a bug someone silenced.
data ExceptionEntry = ExceptionEntry
  { exceptionRow :: RowId,
    exceptionKey :: Text,
    exceptionField :: Maybe Text,
    exceptionReason :: Text,
    exceptionOpened :: Day,
    exceptionOwner :: Text
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON ExceptionEntry where
  parseJSON = withObject "ExceptionEntry" $ \o ->
    ExceptionEntry
      <$> o .: "row"
      <*> o .: "key"
      <*> o .:? "field"
      <*> o .: "reason"
      <*> o .: "opened"
      <*> o .: "owner"

-- | The waiver file's top level, so the YAML has a named key rather than a bare list.
newtype ExceptionFile = ExceptionFile {exceptionFileEntries :: [ExceptionEntry]}

instance FromJSON ExceptionFile where
  parseJSON = withObject "reconcile-exceptions.yaml" $ \o ->
    ExceptionFile <$> (maybe [] id <$> o .:? "exceptions")

-- | Read the waiver file, or say why it could not be read.
--
-- 'Left' carries the YAML parser's own message, which names the line. A malformed waiver file must
-- be loud: the alternative is a run that silently treats every waiver as absent and reports a wall
-- of unexplained divergences, which reads as a data problem and is not one.
loadExceptions :: FilePath -> IO (Either String [ExceptionEntry])
loadExceptions path = do
  r <- Yaml.decodeFileEither path
  pure $ case r of
    Left e -> Left (path <> ": " <> Yaml.prettyPrintParseException e)
    Right f -> Right (exceptionFileEntries f)

-- | Split a row's divergences into @(unexplained, explained)@.
--
-- Only entries for THIS row apply. An entry naming @R3@ explains nothing in R5 even if the key and
-- field match, because the same key means different things in different rows — a DRep id is a
-- membership key in R1 and a profile key in R2, and a waiver for one is not a waiver for the other.
applyExceptions :: [ExceptionEntry] -> RowId -> [Divergence] -> ([Divergence], [Divergence])
applyExceptions es row ds = (filter (not . explained) ds, filter explained ds)
  where
    mine = [e | e <- es, exceptionRow e == row]
    explained d = any (`covers` d) mine

-- | Does this entry explain this divergence?
covers :: ExceptionEntry -> Divergence -> Bool
covers e d =
  exceptionKey e == divergenceKey d
    && maybe True (== divergenceField d) (exceptionField e)

-- | The entries that explained nothing in this run.
--
-- A stale waiver is reported, not deleted automatically: deleting it is a decision with an owner,
-- and the report naming it is how that owner finds out. It is also the only signal that a
-- divergence was FIXED — the waiver outliving the problem is what tells you the problem is gone.
--
-- A SKIPPED row's entries are not stale: nothing was compared, so nothing could have matched. A run
-- that aborted must not propose deleting the waivers it never reached.
staleExceptions :: [ExceptionEntry] -> [RowResult] -> [ExceptionEntry]
staleExceptions es rows = [e | e <- es, not (matched e)]
  where
    compared = [r | r <- rows, not (isSkipped (rowStatus r))]
    matched e =
      any
        (\r -> rowId r == exceptionRow e && any (covers e) (rowExplained r))
        compared

-- ---------------------------------------------------------------------------------------------

-- * One row's outcome

-- | What happened to one row.
--
-- 'RowSkipped' carries WHY, because a skipped row is the one outcome a reader cannot infer: a row
-- with no divergences and a row that was never compared look identical in a count.
data RowStatus = RowOk | RowDivergent | RowSkipped Text
  deriving stock (Show, Eq, Generic)

-- | Was this row never compared?
isSkipped :: RowStatus -> Bool
isSkipped = \case
  RowSkipped _ -> True
  _ -> False

-- | One row of the report.
--
-- @compared@ is the number of KEYS the row looked at, not the number of divergences. It is what
-- makes a clean row meaningful: "R1 ok" says nothing, "R1 ok over 294 keys" says the comparison
-- actually ran, and a row whose compared count collapses to 0 is a broken snapshot rather than a
-- perfect agreement.
data RowResult = RowResult
  { rowId :: RowId,
    rowCompared :: Int,
    rowStatus :: RowStatus,
    rowUnexplained :: [Divergence],
    rowExplained :: [Divergence]
  }
  deriving stock (Show, Eq, Generic)

-- | Build a row, applying the waivers that belong to it.
--
-- The status is 'RowOk' when nothing is left UNEXPLAINED — an explained divergence is a known,
-- owned difference and does not fail the row. That is the whole point of the waiver file, and it is
-- why 'rowExplained' travels: the report shows what was waived rather than hiding it.
mkRow :: [ExceptionEntry] -> RowId -> Int -> [Divergence] -> RowResult
mkRow es row compared ds =
  RowResult
    { rowId = row,
      rowCompared = compared,
      rowStatus = if null unexplained then RowOk else RowDivergent,
      rowUnexplained = sortOn divergenceKey unexplained,
      rowExplained = sortOn divergenceKey explained
    }
  where
    (unexplained, explained) = applyExceptions es row ds

-- | A row that could not be compared, and why.
skippedRow :: RowId -> Text -> RowResult
skippedRow row why =
  RowResult
    { rowId = row,
      rowCompared = 0,
      rowStatus = RowSkipped why,
      rowUnexplained = [],
      rowExplained = []
    }

-- ---------------------------------------------------------------------------------------------

-- * Freshness

-- | Whether the two indexes are close enough in time to be compared at all.
data Freshness = Fresh | Aborted Text
  deriving stock (Show, Eq, Generic)

-- | R10: the guard that runs before anything is compared.
--
-- __Two indexes at different tips disagree about everything that moved between them, and that
-- disagreement is not a defect in either.__ Without this guard a reconciliation run during a busy
-- epoch produces a wall of divergences that are all artefacts of timing, and a reader who chases
-- one of them finds nothing wrong. So the run aborts instead of reporting.
--
-- __An epoch skew of ONE is fine.__ The two indexes do not cross an epoch boundary at the same
-- instant, and a run started seconds before one will see 320 on one side and 321 on the other. Two
-- is not fine: that is a whole epoch of votes, power and lifecycle transitions.
--
-- The skew is absolute — ahead or behind, the comparison is equally meaningless — and the lag bound
-- is a parameter rather than a constant because the caller knows what it is reconciling: a nightly
-- run against a synced index wants seconds, a run against a catching-up one wants minutes.
checkFreshness ::
  -- | our epoch
  Int ->
  -- | Koios's epoch
  Int ->
  -- | our lag behind the chain, in seconds
  Int ->
  -- | the lag we will tolerate, in seconds
  Int ->
  Freshness
checkFreshness ourEpoch koiosEpoch lagSeconds lagBound
  | skew > 1 =
      Aborted
        ( "epoch skew "
            <> tshow skew
            <> " > 1 (ours "
            <> tshow ourEpoch
            <> ", koios "
            <> tshow koiosEpoch
            <> ")"
        )
  | lagSeconds > lagBound =
      Aborted ("lag " <> tshow lagSeconds <> "s > " <> tshow lagBound <> "s")
  | otherwise = Fresh
  where
    skew = abs (koiosEpoch - ourEpoch)

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- ---------------------------------------------------------------------------------------------

-- * The report

-- | The run's verdict.
data ReportStatus = ReportOk | ReportDivergent | ReportAborted
  deriving stock (Show, Eq, Generic)

-- | One reconciliation run.
--
-- The two epochs and the lag are carried even on a clean run, because a report that does not say
-- WHEN and against WHAT is not evidence of anything a week later.
data Report = Report
  { reportNetwork :: Text,
    reportAt :: UTCTime,
    reportOurEpoch :: Int,
    reportLagSeconds :: Int,
    reportKoiosEpoch :: Int,
    reportRows :: [RowResult],
    reportStaleExceptions :: [ExceptionEntry],
    reportStatus :: ReportStatus,
    reportUnexplained :: Int,
    -- | How many divergences a waiver accounted for. Published beside 'reportUnexplained' rather
    -- than left implicit: a run whose explained count is climbing is a run whose waiver file is
    -- doing more work every week, which is worth seeing before it is worth investigating.
    reportExplained :: Int
  }
  deriving stock (Show, Eq, Generic)

-- | Assemble the report. The ONE constructor, so status and exit code cannot be derived twice.
--
-- __'ReportAborted' whenever ANY row is skipped__, before counting divergences. A run that could
-- not compare R3 has not checked R3, and a report that said "ok" with R3 missing would be a false
-- pass — which is worse than no report. This is also the only path to exit 3, so a caller needs no
-- abort branch of its own.
mkReport ::
  Text ->
  UTCTime ->
  -- | our epoch
  Int ->
  -- | our lag, seconds
  Int ->
  -- | Koios's epoch
  Int ->
  [ExceptionEntry] ->
  [RowResult] ->
  Report
mkReport network at ourEpoch lagSeconds koiosEpoch es rows =
  Report
    { reportNetwork = network,
      reportAt = at,
      reportOurEpoch = ourEpoch,
      reportLagSeconds = lagSeconds,
      reportKoiosEpoch = koiosEpoch,
      reportRows = rows,
      reportStaleExceptions = staleExceptions es rows,
      reportStatus =
        if any (isSkipped . rowStatus) rows
          then ReportAborted
          else if unexplained > 0 then ReportDivergent else ReportOk,
      reportUnexplained = unexplained,
      reportExplained = sum (map (length . rowExplained) rows)
    }
  where
    unexplained = sum (map (length . rowUnexplained) rows)

-- | 0 clean or explained, 1 unexplained, 3 aborted.
--
-- __2 is deliberately absent.__ It belongs to the executable and means "Koios did not answer":
-- a transport failure is not a parity finding, and a caller that cannot tell the two apart will
-- either page someone over a network blip or ignore a real divergence as one.
reportExitCode :: Report -> Int
reportExitCode r = case reportStatus r of
  ReportOk -> 0
  ReportDivergent -> 1
  ReportAborted -> 3

-- ---------------------------------------------------------------------------------------------

-- * The two snapshots

-- | Everything one Koios run read, one field per endpoint.
--
-- A record of what was FETCHED, not a model of governance: the reconciler compares two readings of
-- the same chain, so each side keeps the shape its source gave it and the comparison does the
-- translating. The keyed fields are maps because that is how they were requested — one call per id.
data KoiosSnapshot = KoiosSnapshot
  { ksTip :: KoiosTip,
    ksDRepList :: [KoiosDRepListRow],
    ksDRepInfo :: [KoiosDRepInfo],
    ksPower :: [KoiosPowerRow],
    ksProposals :: [KoiosProposal],
    -- | @gov_action1…@ → that action's votes, latest per voter
    ksProposalVotes :: Map Text [KoiosVoteRow],
    -- | @drep1…@ → that DRep's whole vote history
    ksDRepVotes :: Map Text [KoiosDRepVoteRow],
    ksCommittee :: [KoiosCommittee]
  }
  deriving stock (Show, Eq, Generic)

-- | One DRep, reduced to what R1 and R2 compare.
data PDRep = PDRep
  { pdrepHasScript :: Bool,
    pdrepStatus :: DRepStatus,
    pdrepActiveUntilEpoch :: Maybe Int,
    pdrepDelegatorCount :: Int
  }
  deriving stock (Show, Eq, Generic)

-- | One governance action, reduced to what R5 compares.
data PAction = PAction
  { pactionType :: GovActionType,
    pactionProposedEpoch :: Int,
    pactionExpiresEpoch :: Maybe Int,
    pactionRatifiedEpoch :: Maybe Int,
    pactionEnactedEpoch :: Maybe Int,
    pactionDroppedEpoch :: Maybe Int,
    pactionExpiredEpoch :: Maybe Int
  }
  deriving stock (Show, Eq, Generic)

-- | The committee, reduced to what R8 compares: the quorum, and per cold id the hot key and the
-- term's end.
data PCommittee = PCommittee
  { pcommitteeQuorumNumerator :: Int,
    pcommitteeQuorumDenominator :: Int,
    -- | @cc_cold1…@ → (hot key hash in hex, expiration epoch)
    pcommitteeMembers :: Map Text (Maybe Text, Int)
  }
  deriving stock (Show, Eq, Generic)

-- | Everything one run read from OUR API, reduced to the fields the ten rows compare.
--
-- __A projection, not the response DTOs themselves,__ and that is a deliberate split. The rows
-- compare nine values; 'DRepSummary' alone carries twenty-two, and a snapshot built from the DTOs
-- would make every test case in 'rowTests' spell out thirteen fields nobody reads to assert one
-- that is. The DTO dependency is kept where it belongs — in the @from*@ projections below, which
-- is also where a field rename has to break — and the comparison is over types a test can build on
-- one line.
--
-- The projections are exercised end to end by @admin reconcile-koios@ against the live API, which
-- is the only place they CAN be exercised honestly: a unit test that hand-builds a 'DRepSummary'
-- proves that the test author and the projection agree, not that the API serves what we think.
data PalmaresSnapshot = PalmaresSnapshot
  { psEpoch :: Int,
    psLagSeconds :: Int,
    -- | CIP-129 @drep1…@ → its profile
    psDReps :: Map Text PDRep,
    -- | @(drep id, epoch)@ → lovelace. Includes BOTH reserved ledger options (D-20).
    psPower :: Map (Text, Int) Integer,
    -- | CIP-129 @gov_action1…@ → its lifecycle
    psActions :: Map Text PAction,
    -- | @(action, role, verdict)@ → count, over FINAL votes only
    psTallies :: Map (Text, VoterRole, Vote) Int,
    -- | @(action, verdict, vote tx hash)@, the DRep vote HISTORY including superseded votes
    psVotes :: Set (Text, Vote, Text),
    psCommittee :: PCommittee,
    -- | @(beneficiary, amount)@ → count, a multiset over every action's withdrawals
    psWithdrawals :: Map (Text, Integer) Int
  }
  deriving stock (Show, Eq, Generic)

-- ---------------------------------------------------------------------------------------------

-- * The ten rows

-- | Reconcile the two snapshots into ten rows.
--
-- __R10 runs FIRST and its failure skips everything else.__ Comparing two indexes at different
-- tips manufactures divergences that are artefacts of timing and not defects in either side, so a
-- run that cannot establish freshness reports R10 divergent and R1–R9 'RowSkipped' — never a pass.
-- 'mkReport' turns any skipped row into 'ReportAborted', which is the only path to exit 3.
--
-- Each row is one 'diffKeyed' call. What each one compares is the specification; the signature and
-- the tests do not determine it, so it is written out beside each row.
reconcileAll :: KoiosSnapshot -> PalmaresSnapshot -> [ExceptionEntry] -> [RowResult]
reconcileAll k p es = case checkFreshness (psEpoch p) (koiosTipEpochNo (ksTip k)) (psLagSeconds p) readyMaxLagSeconds of
  Aborted why ->
    mkRow es R10 1 [Divergence "freshness" "epoch_skew" (tshow (koiosTipEpochNo (ksTip k))) (tshow (psEpoch p))]
      : [skippedRow r why | r <- [R1 .. R9]]
  Fresh ->
    [ rowMembership,
      rowProfile,
      rowPower,
      rowPowerTotal,
      rowLifecycle,
      rowTally,
      rowVoteHistory,
      rowCommittee,
      rowWithdrawals,
      mkRow es R10 1 []
    ]
  where
    -- R1: the registry's membership. Koios's registered list against our own, as SETS — a DRep on
    -- one side only is the whole finding, and there is nothing else to compare about it.
    rowMembership =
      mkRow es R1 (M.size koiosDReps `max` M.size (psDReps p)) $
        diffKeyed id (\_ _ -> []) koiosDReps (psDReps p)

    -- R2: the profile. `deposit` is deliberately absent — it is the protocol constant
    -- epoch_param.drep_deposit, our DRepSummary does not carry it, and fetching it would cost 294
    -- extra calls to compare a constant.
    rowProfile =
      mkRow es R2 (M.size koiosInfo) $
        diffKeyed id profileDiff koiosInfo (psDReps p)

    profileDiff i d =
      concat
        [ ["has_script" `differs` (tshow (koiosDRepInfoHasScript i), tshow (pdrepHasScript d))
            | koiosDRepInfoHasScript i /= pdrepHasScript d],
          ["active_until_epoch" `differs` (tshow (koiosDRepInfoExpiresEpochNo i), tshow (pdrepActiveUntilEpoch d))
            | koiosDRepInfoExpiresEpochNo i /= pdrepActiveUntilEpoch d],
          -- Koios splits what we join: `registered` plus `active` is our single status.
          ["status" `differs` (tshow koiosStatus, tshow (Just (pdrepStatus d)))
            | koiosStatus /= Just (pdrepStatus d)],
          ["delegator_count" `differs` (tshow (koiosDRepInfoLiveDelegatorCount i), tshow (pdrepDelegatorCount d))
            | koiosDRepInfoLiveDelegatorCount i /= pdrepDelegatorCount d]
        ]
      where
        koiosStatus = koiosDRepStatus (koiosDRepInfoStatus i) (koiosDRepInfoActive i)

    -- R3: voting power, per (DRep, epoch), EXACT lovelace. Both sides read drep_distr, so a
    -- tolerance here would hide a bug rather than absorb a rounding difference.
    rowPower =
      mkRow es R3 (M.size koiosPower) $
        diffKeyed renderPowerKey lovelaceDiff koiosPower (psPower p)

    lovelaceDiff a b = ["lovelace" `differs` (tshow a, tshow b) | a /= b]

    -- R4: the per-epoch TOTAL, including both reserved ledger options (D-20). This is spec check
    -- 5's "documented tolerance" and the tolerance is ZERO: the 46% one used to need was the
    -- pseudo-DRep filter, not a measurement error.
    rowPowerTotal =
      mkRow es R4 (M.size koiosTotals) $
        diffKeyed tshow totalDiff koiosTotals palmaresTotals

    totalDiff a b = ["total_lovelace" `differs` (tshow a, tshow b) | a /= b]

    -- R5: the lifecycle, population-wide over every action, not a sample. These five epochs are
    -- what our own `state` is derived from, so a mismatch in one means the two indexes disagree
    -- about what the ledger did.
    rowLifecycle =
      mkRow es R5 (M.size koiosActions) $
        diffKeyed id lifecycleDiff koiosActions (psActions p)

    lifecycleDiff ka pa =
      concat
        [ ["type" `differs` (tshow (koiosActionType (koiosProposalType ka)), tshow (Just (pactionType pa)))
            | koiosActionType (koiosProposalType ka) /= Just (pactionType pa)],
          cmp "proposed_epoch" (koiosProposalProposedEpoch ka) (Just (pactionProposedEpoch pa)),
          cmp "expires_epoch" (koiosProposalExpiration ka) (pactionExpiresEpoch pa),
          cmp "ratified_epoch" (koiosProposalRatifiedEpoch ka) (pactionRatifiedEpoch pa),
          cmp "enacted_epoch" (koiosProposalEnactedEpoch ka) (pactionEnactedEpoch pa),
          cmp "dropped_epoch" (koiosProposalDroppedEpoch ka) (pactionDroppedEpoch pa),
          cmp "expired_epoch" (koiosProposalExpiredEpoch ka) (pactionExpiredEpoch pa)
        ]
      where
        cmp f a b = [f `differs` (tshow a, tshow b) | a /= b]

    -- R6: the tally, as a (role, verdict) -> count map over the LATEST vote per voter. Koios
    -- collapses re-votes itself, and our tallies read palmares.vote WHERE seq_last = 1, so the two
    -- are counting the same thing in different ways.
    rowTally =
      mkRow es R6 (M.size koiosTallies) $
        diffKeyed renderTallyKey countDiff koiosTallies (psTallies p)

    countDiff a b = ["count" `differs` (tshow a, tshow b) | a /= b]

    -- R7: the vote HISTORY, superseded votes included — which is the gate on GET /votes returning
    -- every palmares.vote row rather than only the final ones. DRep role only: preprod carries
    -- 3,243,802 committee vote rows of test spam, so no row compares committee history.
    rowVoteHistory =
      mkRow es R7 (S.size koiosVoteSet `max` S.size (psVotes p)) $
        diffKeyed renderVoteKey (\_ _ -> []) (setToMap koiosVoteSet) (setToMap (psVotes p))

    -- R8: the quorum under one key, then the members under their cold ids. Two key spaces in one
    -- row because they are one fact about one committee; `status` is excluded, Koios's vocabulary
    -- being its own (`authorized` where we publish `active`).
    rowCommittee =
      mkRow es R8 (1 + M.size koiosMembers) $
        diffKeyed id quorumDiff (M.singleton "committee" koiosQuorum) (M.singleton "committee" palmaresQuorum)
          <> diffKeyed id memberDiff koiosMembers (pcommitteeMembers (psCommittee p))

    quorumDiff a b = ["quorum" `differs` (a, b) | a /= b]

    memberDiff (kh, ke) (ph, pe) =
      concat
        [ ["hot_hash" `differs` (tshow kh, tshow ph) | kh /= ph],
          ["expiration_epoch" `differs` (tshow ke, tshow pe) | ke /= pe]
        ]

    -- R9: withdrawals as a (beneficiary, amount) MULTISET. A multiset and not a set because the
    -- same beneficiary may legitimately appear twice in one action, and collapsing that would make
    -- a duplicated row invisible.
    rowWithdrawals =
      mkRow es R9 (M.size koiosWithdrawals) $
        diffKeyed renderWithdrawalKey countDiff koiosWithdrawals (psWithdrawals p)

    -- ---- Koios's side, reduced the same way ours is -----------------------------------------

    koiosDReps = M.fromList [(koiosDRepListId r, ()) | r <- ksDRepList k, koiosDRepListRegistered r]
    koiosInfo = M.fromList [(koiosDRepInfoId i, i) | i <- ksDRepInfo k]
    koiosPower =
      M.fromList
        [ ((koiosPowerDRepId r, koiosPowerEpochNo r), lovelaceOf r)
          | r <- ksPower k
        ]
    koiosTotals = M.fromListWith (+) [(koiosPowerEpochNo r, lovelaceOf r) | r <- ksPower k]
    lovelaceOf = toInteger . unKoiosLovelace . koiosPowerAmount
    palmaresTotals = M.fromListWith (+) [(e, v) | ((_, e), v) <- M.toList (psPower p)]
    koiosActions = M.fromList [(koiosProposalId a, a) | a <- ksProposals k]

    koiosTallies =
      M.fromListWith (+) $
        [ ((act, role, verdict), 1 :: Int)
          | (act, rows) <- M.toList (ksProposalVotes k),
            r <- rows,
            Just role <- [koiosVoterRole (koiosVoteRole r)],
            Just verdict <- [koiosVote (koiosVoteVote r)]
        ]

    koiosVoteSet =
      S.fromList
        [ (koiosDRepVoteProposalId r, verdict, koiosDRepVoteTxHash r)
          | rows <- M.elems (ksDRepVotes k),
            r <- rows,
            Just verdict <- [koiosVote (koiosDRepVoteVote r)]
        ]

    (koiosQuorum, koiosMembers) = case ksCommittee k of
      (c : _) ->
        ( tshow (koiosCommitteeQuorumNumerator c) <> "/" <> tshow (koiosCommitteeQuorumDenominator c),
          M.fromList
            [ (koiosMemberColdId m, (koiosMemberHotHex m, fromMaybe 0 (koiosMemberExpirationEpoch m)))
              | m <- koiosCommitteeMembers c
            ]
        )
      [] -> ("", M.empty)

    palmaresQuorum =
      tshow (pcommitteeQuorumNumerator (psCommittee p))
        <> "/"
        <> tshow (pcommitteeQuorumDenominator (psCommittee p))

    koiosWithdrawals =
      M.fromListWith (+) $
        [ ((koiosWithdrawalStakeAddress w, toInteger (unKoiosLovelace (koiosWithdrawalAmount w))), 1 :: Int)
          | a <- ksProposals k,
            w <- koiosProposalWithdrawals a
        ]

-- | A set as a map to unit, so 'diffKeyed' serves a membership-only row too.
--
-- One primitive and no second one for sets: a membership divergence is the same finding whether
-- the row compares fields or not, and a set-specific comparator would be a second place for the
-- rendering of that finding to drift.
setToMap :: (Ord a) => Set a -> Map a ()
setToMap = M.fromSet (const ())

-- | @\<drep_id\>:\<epoch\>@, R3's key.
renderPowerKey :: (Text, Int) -> Text
renderPowerKey (d, e) = d <> ":" <> tshow e

-- | @\<gov_action1…\>:\<role\>:\<verdict\>@, R6's key, in the wire spellings a client sees.
renderTallyKey :: (Text, VoterRole, Vote) -> Text
renderTallyKey (a, role, verdict) = a <> ":" <> jsonTag role <> ":" <> jsonTag verdict

-- | @\<gov_action1…\>:\<verdict\>:\<vote_tx_hash\>@, R7's key.
renderVoteKey :: (Text, Vote, Text) -> Text
renderVoteKey (a, verdict, txh) = a <> ":" <> jsonTag verdict <> ":" <> txh

-- | @\<stake_address\>:\<amount\>@, R9's key.
renderWithdrawalKey :: (Text, Integer) -> Text
renderWithdrawalKey (addr, amt) = addr <> ":" <> tshow amt

-- ---------------------------------------------------------------------------------------------

-- * The pinned sample

-- | Which DReps and which actions a run reconciles, read from a COMMITTED file.
--
-- __Pinned, not drawn at run time.__ Two rows cannot be compared population-wide — R7 would have to
-- page every DRep's whole vote history, R6 and R9 one request per action — so they run over a
-- sample. A sample drawn at run time makes the check unfalsifiable: a divergence that appears one
-- night and not the next could be a fix, a regression, or a different sample, and nothing in the
-- report says which. A committed file turns a population change into a @git diff@.
--
-- There is no randomness in it either. A shell script cannot draw a reproducible random sample, so
-- the file is the union of deterministic selectors over two different populations — the heaviest
-- voters and the newest cohort — which is what a fixed seed was being asked to approximate.
--
-- @recorded_at_epoch@ is carried so a report can say the sample is older than the chain it was
-- drawn from, which is the condition under which an id in it may simply no longer exist.
data ReconcileSample = ReconcileSample
  { sampleNetwork :: Text,
    sampleRecordedAtEpoch :: Int,
    -- | R7's population: CIP-129 @drep1…@ ids.
    sampleVoteHistoryDreps :: [Text],
    -- | R6's and R9's population: CIP-129 @gov_action1…@ ids.
    sampleTallyActions :: [Text]
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON ReconcileSample where
  parseJSON = withObject "ReconcileSample" $ \o ->
    ReconcileSample
      <$> o .: "network"
      <*> o .: "recorded_at_epoch"
      <*> o .: "vote_history_dreps"
      <*> o .: "tally_actions"

-- | Read the pinned sample, or say why it could not be read.
--
-- A missing or unreadable file is a 'Left', not an exception. @eitherDecodeFileStrict@ throws on an
-- IO error and only returns 'Left' for a parse error, which would make "the sample is not there" a
-- crash and "the sample is malformed" a message — two spellings of the same operator mistake.
-- 'loadExceptions' has the same contract, via @Data.Yaml@, which does the catching itself.
loadSample :: FilePath -> IO (Either String ReconcileSample)
loadSample path = do
  r <- try (eitherDecodeFileStrict path)
  pure $ case r of
    Left (e :: IOException) -> Left (path <> ": " <> show e)
    Right (Left e) -> Left (path <> ": " <> e)
    Right (Right s) -> Right s

-- | The lag a run will tolerate before aborting, in seconds.
--
-- 300, which is D-7's @PALMARES_READY_MAX_LAG_SECONDS@ — the same bound @\/ready@ uses. The two
-- must agree: a run against an index the service itself calls not-ready is comparing against
-- something no client is being served.
readyMaxLagSeconds :: Int
readyMaxLagSeconds = 300

-- | @(field, koios, palmares)@, spelled so a comparator reads as a sentence.
differs :: Text -> (Text, Text) -> (Text, Text, Text)
differs f (a, b) = (f, a, b)

-- ---------------------------------------------------------------------------------------------

-- * Recorded snapshots

-- | Read a Koios snapshot from a directory of raw response bodies.
--
-- __One file per endpoint, named after it,__ so the recorded layout lives in exactly one place and
-- a reader of the directory can see which call produced which file. The five keyed files
-- (@proposal_votes@, @drep_votes@) are one JSON object keyed by the id the call was made for; the
-- flat ones are the concatenated rows of a paged fetch.
--
-- The point of recording is that CI can replay a real reconciliation with __no network at all__,
-- so a nightly outage of either service can never fail a pull request. It is also the tool that
-- captures the evidence when the nightly DOES diverge: the pair that produced a finding is a file
-- somebody can read six weeks later.
loadKoiosSnapshot :: FilePath -> IO (Either String KoiosSnapshot)
loadKoiosSnapshot dir = runExceptT $ do
  KoiosSnapshot
    <$> f "tip.json" firstOf
    <*> f "drep_list.json" pure
    <*> f "drep_info.json" pure
    <*> f "drep_voting_power_history.json" pure
    <*> f "proposal_list.json" pure
    <*> f "proposal_votes.json" pure
    <*> f "drep_votes.json" pure
    <*> f "committee_info.json" pure
  where
    f :: (FromJSON a) => FilePath -> (a -> Either String b) -> ExceptT String IO b
    f name conv = ExceptT (fmap (>>= conv) (readJsonFile (dir </> name)))

    -- /tip answers with a one-element ARRAY, like every other Koios list endpoint.
    firstOf :: [KoiosTip] -> Either String KoiosTip
    firstOf (t : _) = Right t
    firstOf [] = Left "tip.json: Koios returned no tip"

-- | Read our own snapshot from a directory of raw response bodies, and project it.
--
-- The files are what the API SERVED, decoded through the real response DTOs — so a field rename in
-- 'DRepSummary' breaks this at compile time — and then reduced to 'PalmaresSnapshot'. That order
-- matters: decoding first is what makes the recorded pair evidence about the API rather than about
-- the reconciler.
loadPalmaresSnapshot :: FilePath -> IO (Either String PalmaresSnapshot)
loadPalmaresSnapshot dir = runExceptT $ do
  status <- f "status.json"
  dreps <- f "dreps.json"
  power <- f "drep_power.json"
  actions <- f "gov_actions.json"
  details <- f "gov_action_detail.json"
  votes <- f "votes.json"
  committee <- f "committee.json"
  pure (mkPalmaresSnapshot status dreps power actions details votes committee)
  where
    f :: (FromJSON a) => FilePath -> ExceptT String IO a
    f name = ExceptT (readJsonFile (dir </> name))

-- | Decode one file, naming it in any error.
readJsonFile :: (FromJSON a) => FilePath -> IO (Either String a)
readJsonFile path = do
  r <- try (eitherDecodeFileStrict path)
  pure $ case r of
    Left (e :: IOException) -> Left (path <> ": " <> show e)
    Right (Left e) -> Left (path <> ": " <> e)
    Right (Right a) -> Right a

-- | Build the projection from what our API served.
--
-- This is the ONLY place the response DTOs are read, which is the point: nine comparison values
-- against twenty-two DTO fields, with the translation in one function instead of scattered through
-- ten rows.
mkPalmaresSnapshot ::
  StatusResponse ->
  [DRepSummary] ->
  -- | @drep1…@ → its power series
  Map Text [EpochPowerPoint] ->
  [GovActionSummary] ->
  -- | @gov_action1…@ → its detail
  Map Text GovActionDetailResponse ->
  -- | @drep1…@ → its vote history
  Map Text [VoteRecord] ->
  CommitteeResponse ->
  PalmaresSnapshot
mkPalmaresSnapshot status dreps power actions details votes committee =
  PalmaresSnapshot
    { psEpoch = syncEpoch (statusGovernance status),
      psLagSeconds = syncLagSeconds (statusGovernance status),
      psDReps =
        M.fromList
          [ ( unDRepId (drepSummaryId d),
              PDRep
                (drepSummaryHasScript d)
                (drepSummaryStatus d)
                (drepSummaryActiveUntilEpoch d)
                (drepSummaryDelegatorCount d)
            )
            | d <- dreps
          ],
      psPower =
        M.fromList
          [ ((i, epochPowerEpoch pt), epochPowerLovelace pt)
            | (i, pts) <- M.toList power,
              pt <- pts
          ],
      psActions =
        M.fromList
          [ ( govActionSummaryBech32 a,
              PAction
                (govActionSummaryType a)
                (chainPointEpoch (govActionSummaryProposedAt a))
                (govActionSummaryExpiresEpoch a)
                (govActionLifecycleRatifiedEpoch (govActionSummaryLifecycle a))
                (govActionLifecycleEnactedEpoch (govActionSummaryLifecycle a))
                (govActionLifecycleDroppedEpoch (govActionSummaryLifecycle a))
                (govActionLifecycleExpiredEpoch (govActionSummaryLifecycle a))
            )
            | a <- actions
          ],
      -- A tally row carries three counts, so it expands to three keys — and a ZERO count is
      -- dropped, because Koios has no row for a verdict nobody cast and a 0 on one side against an
      -- absent key on the other would be a membership divergence on every action.
      psTallies =
        M.fromList
          [ ((act, voteTallyRole t, verdict), n)
            | (act, d) <- M.toList details,
              t <- govActionDetailTallies d,
              (verdict, n) <-
                [ (Yes, voteTallyYesCount t),
                  (No, voteTallyNoCount t),
                  (Abstain, voteTallyAbstainCount t)
                ],
              n > 0
          ],
      psVotes =
        S.fromList
          [ (voteRecordGovActionBech32 v, voteRecordVerdict v, txh)
            | vs <- M.elems votes,
              v <- vs,
              -- DRep role only: R7 compares DRep history, and preprod's committee vote rows are
              -- 3.24 M of test spam.
              voteRecordVoterRole v == DRep,
              Just txh <- [chainPointTxHash (voteRecordCastAt v)]
          ],
      psCommittee =
        PCommittee
          (committeeQuorumNumerator committee)
          (committeeQuorumDenominator committee)
          ( M.fromList
              [ (committeeMemberColdBech32 m, (committeeMemberHotHash m, committeeMemberExpirationEpoch m))
                | m <- committeeMembers committee
              ]
          ),
      psWithdrawals =
        M.fromListWith
          (+)
          [ ((treasuryWithdrawalBeneficiary w, treasuryWithdrawalAmount w), 1 :: Int)
            | d <- M.elems details,
              w <- govActionDetailWithdrawals d
          ]
    }

-- ---------------------------------------------------------------------------------------------

-- * The report on the wire

-- | @out\/divergences.json@.
--
-- Hand-written rather than derived, because this file is READ BY PEOPLE and by the wrapper's jq:
-- the key names are the contract, and a @deriving via CustomJSON@ would make them a consequence of
-- the Haskell field names. @reportStaleExceptions@ becoming @stale_exceptions@ is the kind of
-- rename that should be a decision, not a side effect.
--
-- Both @unexplained@ and @explained@ travel, and the rows carry their divergences in full. A
-- report that only said "1 unexplained" would make every investigation start with another run.
instance ToJSON Report where
  toJSON r =
    object
      [ "network" .= reportNetwork r,
        "ran_at" .= reportAt r,
        "palmares_epoch" .= reportOurEpoch r,
        "palmares_lag_seconds" .= reportLagSeconds r,
        "koios_epoch" .= reportKoiosEpoch r,
        "status" .= reportStatus r,
        "unexplained" .= reportUnexplained r,
        "explained" .= reportExplained r,
        "stale_exceptions" .= reportStaleExceptions r,
        "rows" .= reportRows r
      ]

instance ToJSON ReportStatus where
  toJSON = String . \case
    ReportOk -> "ok"
    ReportDivergent -> "divergent"
    ReportAborted -> "aborted"

-- | A row, with its divergences in full.
--
-- @skipped_reason@ appears only on a skipped row, and @status@ is @\"skipped\"@ there rather than a
-- fourth value shoehorned into the reason: a reader scanning for failures must not have to parse
-- prose to tell a clean row from an unreached one.
instance ToJSON RowResult where
  toJSON r =
    object $
      [ "row" .= rowIdText (rowId r),
        "compared" .= rowCompared r,
        "status" .= rowStatus r,
        "unexplained" .= rowUnexplained r,
        "explained" .= rowExplained r
      ]
        <> case rowStatus r of
          RowSkipped why -> ["skipped_reason" .= why]
          _ -> []

instance ToJSON RowStatus where
  toJSON = String . \case
    RowOk -> "ok"
    RowDivergent -> "divergent"
    RowSkipped _ -> "skipped"

-- | @koios@ and @palmares@, never @expected@ and @actual@ — see the module header.
instance ToJSON Divergence where
  toJSON d =
    object
      [ "key" .= divergenceKey d,
        "field" .= divergenceField d,
        "koios" .= divergenceKoios d,
        "palmares" .= divergencePalmares d
      ]

-- | A stale waiver, echoed back in the shape the file wrote it, so the line can be deleted by
-- copying it out of the report.
instance ToJSON ExceptionEntry where
  toJSON e =
    object $
      [ "row" .= rowIdText (exceptionRow e),
        "key" .= exceptionKey e,
        "reason" .= exceptionReason e,
        "opened" .= exceptionOpened e,
        "owner" .= exceptionOwner e
      ]
        <> maybe [] (\f -> ["field" .= f]) (exceptionField e)
