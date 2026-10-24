{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The epoch-319 regression gate (S2).
--
-- Runs the CATALOG's SQL — looked up by @formula_id@, bound with the catalog's own @params@ order
-- — against a real synced db-sync, and compares every number with
-- @test\/fixtures\/preprod-epoch-320-metrics.json@. There is no second copy of any formula here,
-- which is the point: this test cannot pass by agreeing with itself.
--
-- It needs the caught-up preprod database, which takes about seven hours to build, so it cannot
-- run in CI. @PALMARES_FIXTURE_PG_CONN_STR@ selects it, and without that variable each case is
-- SKIPPED WITH A NOTICE on stderr rather than silently passing. That is deliberately different
-- from "Test.Pg dies when its variable is missing": the schema tests need any PostgreSQL and a
-- developer always has one.
--
-- __But a notice on stderr is not a result__ (@TD-14@). All eight cases below reported @OK@ with
-- the variable unset, so every run that forgot it — every CI run, and any by-hand signing run
-- where the export was missed — read as "the epoch-319 gate passed" when the gate had not
-- executed a single statement. A skipped test that reports green is worse than a missing one,
-- because the suite's green then asserts something nobody checked.
--
-- @PALMARES_REQUIRE_FIXTURE_GATE@ closes that. Set to any non-empty value, a skip becomes a
-- FAILURE naming the variable that is missing; unset, the permissive behaviour above stays, so a
-- developer with no synced db-sync can still run the suite. The signing run sets both variables,
-- which is what makes "the gate passed" mean the comparison happened. CI sets the require
-- variable ALONE, on a run filtered to this group, and asserts the suite fails — it cannot
-- provide the database, so what it gates is that the skip can never silently go back to green.
--
-- The fixture pins epoch 319 and not the tip. An open epoch has no stable cursor: @age_days_v1@
-- takes @max(block.time)@ over epochs <= as_of_epoch, which inside an open epoch is "now" and
-- moves every twenty seconds.
module UnitTests.MetricFixture (tests) where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Logger (runNoLoggingT)
import Data.Aeson (FromJSON (..), eitherDecodeFileStrict', withObject, (.:))
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.Persist (PersistValue (PersistInt64, PersistText))
import Database.Persist.Postgresql (withPostgresqlPool)
import Database.Persist.Sql (ConnectionPool, Single (..), rawSql)
import Palmares.Metrics.Catalog
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import Test.Metrics (runMetric)
import Test.Pg (runPg)
import Test.Tasty
import Test.Tasty.HUnit

-- | Only the fields the assertions use. A loader that demanded every key would make adding a
-- documentary note to the fixture a compile error.
data Fixture = Fixture
  { fxCursorHash :: Text,
    fxCursorSlot :: Int64,
    fxDrepHex :: Text,
    fxAsOfEpoch :: Int,
    fxAgeDays :: Double,
    fxAgeTolerance :: Double,
    fxEligible :: Int,
    fxVotesCast :: Int,
    fxParticipation :: Double,
    fxOpenUnvoted :: Int,
    fxRatVerified :: Int,
    fxRatInline :: Int,
    fxRatUnverified :: Int,
    fxRatPending :: Int,
    fxRatAbsent :: Int,
    fxLatencyMedian :: Double,
    fxLatencyP90 :: Double,
    fxLatencySample :: Int,
    fxDelegators :: Int,
    fxVotesByType :: [(Text, Int, Int)],
    fxAbstainLovelace :: Int64,
    fxNoConfidenceLovelace :: Int64
  }

instance FromJSON Fixture where
  parseJSON = withObject "Fixture" $ \o -> do
    cur <- o .: "cursor"
    drep <- o .: "drep"
    m <- o .: "metrics"
    pseudo <- o .: "pseudo_dreps"
    byType <- o .: "votes_by_type"
    Fixture
      <$> cur .: "block_hash"
      <*> cur .: "slot_no"
      <*> drep .: "hex"
      <*> m .: "as_of_epoch"
      <*> m .: "age_days"
      <*> m .: "age_days_tolerance"
      <*> m .: "eligible_actions"
      <*> m .: "votes_cast"
      <*> m .: "participation_rate"
      <*> m .: "open_actions_unvoted"
      <*> m .: "rationale_verified"
      <*> m .: "rationale_inline"
      <*> m .: "rationale_unverified"
      <*> m .: "rationale_pending"
      <*> m .: "rationale_absent"
      <*> m .: "vote_latency_median_hours"
      <*> m .: "vote_latency_p90_hours"
      <*> m .: "vote_latency_sample"
      <*> m .: "delegator_count"
      <*> traverse row byType
      <*> pseudo .: "always_abstain_lovelace"
      <*> pseudo .: "always_no_confidence_lovelace"
    where
      row = withObject "votes_by_type" $ \r ->
        (,,) <$> r .: "action_type" <*> r .: "eligible_actions" <*> r .: "votes_cast"

tests :: TestTree
tests =
  testGroup
    "preprod epoch-320 fixture"
    [ withFixture "the cursor block is still the block the fixture pinned" $ \pool fx -> do
        -- The reason the cursor is pinned by hash: if this block is not where the fixture says it
        -- is, every time-derived number below is being compared against a different chain.
        rows <-
          runPg pool $
            rawSql
              "SELECT encode(b.hash,'hex'), b.slot_no FROM public.block b WHERE b.hash = decode(?,'hex')"
              [PersistText (fxCursorHash fx)]
        map (\(Single h, Single s) -> (h :: Text, s :: Int64)) rows
          @?= [(fxCursorHash fx, fxCursorSlot fx)],
      withFixture "participation_rate_v1 reproduces the fixture" $ \pool fx -> do
        d <- drepId pool fx
        [(Single elig, Single cast, Single rate, Single openUnvoted)] <-
          runMetric pool "participation_rate_v1" [PersistInt64 d, epochOf fx]
        (elig :: Int, cast :: Int, openUnvoted :: Int)
          @?= (fxEligible fx, fxVotesCast fx, fxOpenUnvoted fx)
        fmap (roundTo 6) (rate :: Maybe Double) @?= Just (fxParticipation fx),
      withFixture "rationale_rate_v1's five grades sum to votes_cast" $ \pool fx -> do
        d <- drepId pool fx
        [(Single v, Single inl, Single unv, Single pend, Single ab, Single (_cip :: Int), Single (_r :: Maybe Double))] <-
          runMetric pool "rationale_rate_v1" [PersistInt64 d, epochOf fx]
        (v :: Int, inl :: Int, unv :: Int, pend :: Int, ab :: Int)
          @?= (fxRatVerified fx, fxRatInline fx, fxRatUnverified fx, fxRatPending fx, fxRatAbsent fx)
        -- The invariant, independent of the pinned values: nothing is lost or double-graded.
        v + inl + unv + pend + ab @?= fxVotesCast fx,
      withFixture "age_days_v1 matches the pinned cursor" $ \pool fx -> do
        d <- drepId pool fx
        [Single (days :: Double)] <- runMetric pool "age_days_v1" [PersistInt64 d, epochOf fx]
        assertBool
          (show days <> " is outside " <> show (fxAgeDays fx) <> " +/- " <> show (fxAgeTolerance fx))
          (abs (days - fxAgeDays fx) <= fxAgeTolerance fx),
      withFixture "vote_latency uses percentile_cont, not percentile_disc" $ \pool fx -> do
        d <- drepId pool fx
        [(Single med, Single p90, Single n)] <-
          runMetric pool "vote_latency_median_hours_v1" [PersistInt64 d, epochOf fx]
        -- percentile_cont interpolates between samples. The fixture's median is not a member of
        -- latency_sample_hours, so _disc would fail here.
        (fmap (roundTo 2) (med :: Maybe Double), fmap (roundTo 2) (p90 :: Maybe Double), n :: Int)
          @?= (Just (fxLatencyMedian fx), Just (fxLatencyP90 fx), fxLatencySample fx),
      withFixture "votes_by_type_v1 emits all seven types and sums to the headline figures" $ \pool fx -> do
        d <- drepId pool fx
        rows <- runMetric pool "votes_by_type_v1" [PersistInt64 d, epochOf fx]
        let got =
              [ (t, e, c)
              | ( Single (t :: Text),
                  Single (e :: Int),
                  Single (c :: Int),
                  Single (_y :: Int),
                  Single (_n :: Int),
                  Single (_a :: Int),
                  Single (_r :: Maybe Double)
                  ) <-
                  rows
              ]
        length got @?= 7
        sum [e | (_, e, _) <- got] @?= fxEligible fx
        sum [c | (_, _, c) <- got] @?= fxVotesCast fx
        sortOn (\(t, _, _) -> t) got @?= sortOn (\(t, _, _) -> t) (fxVotesByType fx),
      withFixture "delegator_retention_rate_v1 binds the window, it does not inline it" $ \pool fx -> do
        d <- drepId pool fx
        retentionWindowEpochs @?= 10
        now_ <- retentionNow pool fx d (fromIntegral retentionWindowEpochs)
        fst now_ @?= fxDelegators fx
        -- With the window set to zero, "previous" must equal today. That is only true if the
        -- parameter is really bound, rather than a literal 10 living in the statement.
        zeroWindow <- retentionNow pool fx d 0
        zeroWindow @?= (fxDelegators fx, fxDelegators fx),
      withFixture "the pseudo-DReps carry the dashboard figures and are absent from palmares.drep" $ \pool fx -> do
        [(Single abstain, Single noConf)] <-
          runPg pool $
            rawSql
              "SELECT sum(amount) FILTER (WHERE target_kind = 'always_abstain'), \
              \sum(amount) FILTER (WHERE target_kind = 'always_no_confidence') \
              \FROM palmares.drep_epoch_power WHERE epoch_no = ?"
              [epochOf fx]
        (abstain :: Int64, noConf :: Int64) @?= (fxAbstainLovelace fx, fxNoConfidenceLovelace fx)
        [Single (listed :: Int)] <-
          runPg pool $ rawSql "SELECT count(*)::int FROM palmares.drep WHERE drep_raw IS NULL" []
        listed @?= 0
    ]

epochOf :: Fixture -> PersistValue
epochOf fx = PersistInt64 (fromIntegral (fxAsOfEpoch fx))

-- | The first two counters of the retention statement.
retentionNow :: ConnectionPool -> Fixture -> Int64 -> Int64 -> IO (Int, Int)
retentionNow pool fx d win = do
  rows <-
    runMetric
      pool
      "delegator_retention_rate_v1"
      [PersistInt64 d, epochOf fx, PersistInt64 win]
  case rows of
    [ ( Single (now_ :: Int),
        Single (prev :: Int),
        Single (_ret :: Int),
        Single (_join :: Int),
        Single (_left :: Int),
        Single (_rate :: Maybe Double)
        )
      ] -> pure (now_, prev)
    _ -> fail "delegator_retention_rate_v1 returned an unexpected shape"

-- | Resolve the fixture's hex credential to this database's @drep_hash.id@. Ids are per-database,
-- so the fixture pins the credential and never the id.
drepId :: ConnectionPool -> Fixture -> IO Int64
drepId pool fx = do
  rows <-
    runPg pool $
      rawSql "SELECT id FROM public.drep_hash WHERE raw = decode(?,'hex')" [PersistText (fxDrepHex fx)]
  case rows of
    [Single i] -> pure i
    _ -> fail ("the fixture DRep " <> T.unpack (fxDrepHex fx) <> " is not in this database")

roundTo :: Int -> Double -> Double
roundTo n x = fromIntegral (round (x * 10 ^ n) :: Integer) / 10 ^ n

-- | One case against the fixture database, or a skip — loud on stderr, or fatal under the gate.
--
-- Every case in this module routes through here, so the gate is one branch rather than eight.
withFixture :: TestName -> (ConnectionPool -> Fixture -> IO ()) -> TestTree
withFixture name body = testCase name $ do
  mConn <- lookupEnv "PALMARES_FIXTURE_PG_CONN_STR"
  case mConn of
    Nothing -> do
      -- Non-empty, matching 'Test.Pg.adminConnStr': an empty export is how a shell says "unset",
      -- and a gate that read `PALMARES_REQUIRE_FIXTURE_GATE=` as "on" would fail for nothing.
      required <- lookupEnv "PALMARES_REQUIRE_FIXTURE_GATE"
      case required of
        Just g
          | not (null g) ->
              assertFailure
                ( "PALMARES_REQUIRE_FIXTURE_GATE is set, so a skipped epoch-319 gate is a failure \
                  \rather than a pass: "
                    <> name
                    <> ". Set PALMARES_FIXTURE_PG_CONN_STR to a caught-up preprod db-sync, or unset \
                       \PALMARES_REQUIRE_FIXTURE_GATE to run the suite without one."
                )
        _ ->
          hPutStrLn
            stderr
            ( "SKIPPED (PALMARES_FIXTURE_PG_CONN_STR unset, so the epoch-319 gate did not run): "
                <> name
            )
    Just conn -> do
      parsed <- eitherDecodeFileStrict' "test/fixtures/preprod-epoch-320-metrics.json"
      fx <- either (fail . ("the fixture did not parse: " <>)) pure parsed
      runNoLoggingT $
        withPostgresqlPool (TE.encodeUtf8 (T.pack conn)) 2 $ \pool ->
          liftIO (body pool fx)
