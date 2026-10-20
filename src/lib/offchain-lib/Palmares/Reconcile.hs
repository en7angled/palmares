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

    -- * The report
    ReportStatus (..),
    Report (..),
    mkReport,
    reportExitCode,
  )
where

import Data.Aeson (FromJSON (parseJSON), withObject, withText, (.:), (.:?))
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as M
import Data.Set qualified as S
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (Day, UTCTime)
import Data.Yaml qualified as Yaml
import GHC.Generics (Generic)

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
    reportUnexplained :: Int
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
      reportUnexplained = unexplained
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
